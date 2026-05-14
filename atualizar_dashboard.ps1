<#
.SYNOPSIS
  Regenera dashboard_bacen.html com dados frescos do BigQuery.
  Agendado via Task Scheduler - roda diariamente as 08:00.
  Para rodar manualmente: .\atualizar_dashboard.ps1 -OpenBrowser
#>
param([switch]$OpenBrowser)

Set-StrictMode -Off
& chcp 65001 | Out-Null
$env:PYTHONUTF8 = '1'
# Garante que PowerShell decodifique o output de subprocessos (bq) como UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

$PROJECT = 'meli-bi-data'
$OUT  = "$env:USERPROFILE\Downloads\dashboard_bacen.html"
$REPO = "$env:USERPROFILE\Downloads\monitoramento-bacen"
$LOG = "$env:USERPROFILE\Downloads\dashboard_bacen.log"

function Log($msg) {
    $line = "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Host $line
    Add-Content -Path $LOG -Value $line -Encoding utf8
}

function RunBQ([string]$sql) {
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "bq_$(Get-Random).sql")
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $sql, $enc)
    # Captura saida em arquivo para evitar problemas de encoding no pipeline
    $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "bq_out_$(Get-Random).json")
    $proc = Start-Process -FilePath 'bq' `
        -ArgumentList "query --use_legacy_sql=false --format=json --quiet --project_id=$PROJECT --flagfile=`"$tmp`"" `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError 'NUL' `
        -Wait -PassThru -NoNewWindow
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not (Test-Path $outFile)) { return @() }
    $content = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8).Trim()
    Remove-Item $outFile -ErrorAction SilentlyContinue
    if (-not $content -or $content -notmatch '^\s*[\[\{]') { return @() }
    try { return $content | ConvertFrom-Json }
    catch { Log "AVISO: JSON parse error"; return @() }
}

function J($arr)   { '[' + ($arr -join ',') + ']' }
function JO($dict) {
    $p = $dict.Keys | ForEach-Object {
        $v = $dict[$_]
        if ($v -is [array]) { "'" + $_ + "':" + (J $v) }
        else                { "'" + $_ + "':" + $v }
    }
    '{' + ($p -join ',') + '}'
}
function Esc($s) {
    if (-not $s) { return '' }
    $s = $s -replace "\\","\\\\" -replace "'","\'" -replace "`n"," " -replace "`r",""
    # Converte chars nao-ASCII para \uXXXX evitando problemas de encoding no HTML
    $out = [System.Text.StringBuilder]::new()
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$out.Append('\u{0:x4}' -f [int]$ch) }
        else                  { [void]$out.Append($ch) }
    }
    return $out.ToString()
}

Log "Iniciando atualizacao..."

# ================================================================
# STEP 1 - Recriar tabela materializada 2026
# ================================================================
Log "Recriando tabela Monitoramento_Bacen_nteixeira..."
$q1 = @'
CREATE OR REPLACE TABLE `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
OPTIONS(expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 20 DAY)) AS
WITH primeiro_filtro AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) >= '2026-01-01'
    AND TYPE_CASES = 'cc-commerce'
    AND GCA_SECOND_SUBTYPE = 'casos_especiais_bacen'
    AND SUBTYPE_1 IN (
      "fco-return-consultas-bs","fco-return-revision-manual-bs",
      "fco-return-revision-manual-lt","fco-return-consultas-lt",
      "fco-post-shipped-revision-manual-bs","fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs",
      "fco-pre-shipped-consultas-lt","fraud_seller_user","fraud_seller_user_bof",
      "fraude_com_oferta","fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs",
      "fco-pre-shipped-revision-manual-bs","guardianes_seller_post_shipped",
      "guardianes_seller_return","quadrilha_autofertas_consultas",
      "assoc_ilicita_consultas","fraude_user_bof")
    AND (DERIVACAO_CX IS NULL OR DERIVACAO_CX != 'INCORRECT')
    AND (REASON IS NULL OR REASON != 'DERIVATION_TO_ANOTHER_SECTOR')
),
restricoes_seller AS (
  SELECT * FROM `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW`
  WHERE INFRACTION_TYPE IN (
    'AUTO_OFERTAS_BUYER','AUTO_OFERTAS_SELLER','BOF_BIG_SELLERS','BUYER_PROTECTION_PROGRAM',
    'CUENTA_LARANJA','DANGEROUS_CROSSING','EMPTY_BOX_SELLER_FRAUD','FRAUDE_CUADRILLA',
    'FRAUDE_CUADRILLA_ORDER','FRAUDE_ETIQUETA','LABEL_COST_NO_ME_FRAUD','LEGACY_MIGRATION',
    'SELF_OFFERS_MANUAL_CARDS','SELLER_BONIFICATIONS_NON_EFFECTIVE_DELIVERIES',
    'SELLER_DIFFERENT_OR_DEFECTIVE_PRODUCT','SELLER_FAILED_RETURNS_FRAUD',
    'SELLER_LONG_TAIL_PRE_SHIPPED','SELLER_SHIPMENT_LABEL_FALSIFICATION','SELLERS_SQUAD_FRAUD')
),
casos_com_restricao AS (
  SELECT A.*,B.SENTENCE_DATE,B.INFRACTION_TYPE,B.DETALLE_REGLAS,
         B.DETECTION_TYPE,B.RULE_RISK_LEVELS,B.SENTENCE_REASON,
         ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS com_restricao
  FROM primeiro_filtro AS A
  LEFT JOIN restricoes_seller AS B
    ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED
),
mapeamento_ids AS (
  SELECT GCA_ID,
    SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS clean_sf_id
  FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`
)
SELECT DISTINCT
  c.case_id,c.CUST_ID,c.TYPE_CASES,
  (SELECT COUNT(DISTINCT case_id) FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
   WHERE CUST_ID=c.CUST_id AND DATE_CREATED>c.SENTENCE_DATE AND DATE_CREATED<c.DATE_CREATED) AS qtde_consultas,
  c.GCA_CREATED_MODE,c.SUBTYPE_1,c.admin_case,c.COLA_CX,c.GCA_SECOND_SUBTYPE,
  c.DERIVACAO_CX,c.REASON,
  CAST(c.DATE_CREATED AS DATE) AS DATE_CREATED,
  EXTRACT(MONTH FROM c.DATE_CREATED) AS mes_criacao,
  CAST(c.LAST_UPDATED AS DATE) AS LAST_UPDATED,
  EXTRACT(MONTH FROM c.LAST_UPDATED) AS fechamento_caso,
  rdr.* EXCEPT(CAS_CASE_ID,STATUS_BACEN),
  COALESCE(rdr.STATUS_BACEN,'Nao analisado') AS STATUS_BACEN,
  GREATEST(0,DATE_DIFF(DATE(rdr.INCOMING_DTTM),DATE(c.SENTENCE_DATE),DAY)) AS dias_diff_rdr_incoming_sentence,
  CASE WHEN DATE_DIFF(CAST(c.LAST_UPDATED AS DATE),CAST(c.DATE_CREATED AS DATE),DAY)>=365
       THEN CAST(DATE_DIFF(CAST(c.LAST_UPDATED AS DATE),CAST(c.DATE_CREATED AS DATE),YEAR) AS STRING)||' anos'
       WHEN DATE_DIFF(CAST(c.LAST_UPDATED AS DATE),CAST(c.DATE_CREATED AS DATE),DAY)>=30
       THEN CAST(DATE_DIFF(CAST(c.LAST_UPDATED AS DATE),CAST(c.DATE_CREATED AS DATE),MONTH) AS STRING)||' meses'
       ELSE CAST(DATE_DIFF(CAST(c.LAST_UPDATED AS DATE),CAST(c.DATE_CREATED AS DATE),DAY) AS STRING)||' dias'
  END AS sla_caso,
  c.RESTRICTION_ID_NM,c.SENTENCE_DATE,c.INFRACTION_TYPE,c.DETALLE_REGLAS,
  c.DETECTION_TYPE,
  CASE WHEN CAST(c.RULE_RISK_LEVELS AS INT64)=1 THEN 'Cartao verde'
       WHEN CAST(c.RULE_RISK_LEVELS AS INT64)=2 THEN 'Cartao amarelo'
       WHEN CAST(c.RULE_RISK_LEVELS AS INT64)=3 THEN 'Cartao vermelho'
       ELSE CAST(c.RULE_RISK_LEVELS AS STRING) END AS RULE_RISK_LEVELS,
  c.SENTENCE_REASON,c.ACAO_NO_CASO,
  CASE WHEN c.resolution='Deactive' THEN 'Manteve'
       WHEN c.resolution='Accept'   THEN 'Retirou'
       WHEN c.resolution='Next'     THEN 'Outros'
       ELSE 'Sem analise' END AS resolution,
  c.GCA_COMMENT_CASES,
  CASE WHEN c.SENTENCE_DATE IS NULL THEN 'Outros'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY)>=365
       THEN CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),YEAR) AS STRING)||' anos'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY)>=30
       THEN CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),MONTH) AS STRING)||' meses'
       ELSE CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY) AS STRING)||' dias'
  END AS tempo_acionamento,
  CASE WHEN c.SENTENCE_DATE IS NULL OR rdr.INCOMING_DTTM IS NULL THEN 'mais de 6 dias'
       WHEN DATE_DIFF(DATE(rdr.INCOMING_DTTM),DATE(c.SENTENCE_DATE),DAY)<0 THEN 'menos de 0 dias'
       WHEN DATE_DIFF(DATE(rdr.INCOMING_DTTM),DATE(c.SENTENCE_DATE),DAY) BETWEEN 1 AND 3 THEN '1 a 3 dias'
       WHEN DATE_DIFF(DATE(rdr.INCOMING_DTTM),DATE(c.SENTENCE_DATE),DAY) BETWEEN 4 AND 5 THEN '3 a 5 dias'
       ELSE 'mais de 6 dias' END AS agrupamento_bacen,
  CASE WHEN c.SENTENCE_DATE IS NULL THEN 'mais de 6 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY)<0 THEN 'menos de 0 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY) BETWEEN 1 AND 3 THEN '1 a 3 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY) BETWEEN 4 AND 5 THEN '3 a 5 dias'
       ELSE 'mais de 6 dias' END AS agrupamento_consultas,
  CASE WHEN rdr.INCOMING_DTTM IS NULL THEN 'mais de 6 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(rdr.INCOMING_DTTM),DAY)<0 THEN 'menos de 0 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(rdr.INCOMING_DTTM),DAY) BETWEEN 1 AND 3 THEN '1 a 3 dias'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(rdr.INCOMING_DTTM),DAY) BETWEEN 4 AND 5 THEN '3 a 5 dias'
       ELSE 'mais de 6 dias' END AS agrupamento_bacen_consultas
FROM casos_com_restricao AS c
LEFT JOIN mapeamento_ids m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.clean_sf_id=rdr.CAS_CASE_ID
WHERE c.com_restricao=1 AND c.DATE_CREATED>='2026-01-01'
'@
RunBQ $q1 | Out-Null
Log "Tabela criada."

# ================================================================
# STEP 2 - Queries de dados
# ================================================================
Log "Buscando dados..."

$rRes = RunBQ @'
SELECT mes_criacao AS mes, resolution, RULE_RISK_LEVELS AS cartao,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2,3 ORDER BY 1,2
'@

$rInf = RunBQ @'
SELECT mes_criacao AS mes, IFNULL(INFRACTION_TYPE,'Outros') AS inf,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,3 DESC
'@

$rReg = RunBQ @'
SELECT mes_criacao AS mes, DETALLE_REGLAS AS regra,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE DETALLE_REGLAS IS NOT NULL
GROUP BY 1,2 ORDER BY 1,3 DESC
'@

$rSub = RunBQ @'
SELECT mes_criacao AS mes, SUBTYPE_1 AS sub,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,3 DESC
'@

$rBac = RunBQ @'
SELECT mes_criacao AS mes,
  CASE WHEN LOWER(STATUS_BACEN) LIKE '%improcedente%' THEN 'imp'
       WHEN LOWER(STATUS_BACEN) LIKE '%procedente%'  THEN 'proc'
       WHEN LOWER(STATUS_BACEN) LIKE 'encerrada%'    THEN 'out'
       ELSE 'nao' END AS cat,
  COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,2
'@

$rSla = RunBQ @'
SELECT mes_criacao AS mes, agrupamento_consultas AS ac,
       agrupamento_bacen AS ab, agrupamento_bacen_consultas AS abc,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2,3,4 ORDER BY 1
'@

$rMsgs = RunBQ @'
SELECT CAST(CUST_ID AS STRING) AS id, case_id AS caso,
       SUBSTR(RECLAMACAO_USUARIO,1,280) AS msg
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE RECLAMACAO_USUARIO IS NOT NULL AND RECLAMACAO_USUARIO != ''
ORDER BY DATE_CREATED DESC LIMIT 200
'@

$rMelh = RunBQ @'
SELECT CAST(CUST_ID AS STRING) AS id, case_id AS caso, MELHORIA_BACEN AS mel
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE MELHORIA_BACEN IS NOT NULL AND MELHORIA_BACEN != ''
ORDER BY DATE_CREATED DESC LIMIT 100
'@

$rComp = RunBQ @'
WITH pf25 AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) BETWEEN '2025-01-01' AND '2025-05-31'
    AND TYPE_CASES='cc-commerce' AND GCA_SECOND_SUBTYPE='casos_especiais_bacen'
    AND SUBTYPE_1 IN (
      "fco-return-consultas-bs","fco-return-revision-manual-bs","fco-return-revision-manual-lt",
      "fco-return-consultas-lt","fco-post-shipped-revision-manual-bs",
      "fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs",
      "fco-pre-shipped-consultas-lt","fraud_seller_user","fraud_seller_user_bof",
      "fraude_com_oferta","fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs",
      "fco-pre-shipped-revision-manual-bs","guardianes_seller_post_shipped",
      "guardianes_seller_return","quadrilha_autofertas_consultas",
      "assoc_ilicita_consultas","fraude_user_bof")
    AND (DERIVACAO_CX IS NULL OR DERIVACAO_CX!='INCORRECT')
    AND (REASON IS NULL OR REASON!='DERIVATION_TO_ANOTHER_SECTOR')
),
rs AS (
  SELECT * FROM `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW`
  WHERE INFRACTION_TYPE IN (
    'AUTO_OFERTAS_BUYER','AUTO_OFERTAS_SELLER','BOF_BIG_SELLERS','BUYER_PROTECTION_PROGRAM',
    'CUENTA_LARANJA','DANGEROUS_CROSSING','EMPTY_BOX_SELLER_FRAUD','FRAUDE_CUADRILLA',
    'FRAUDE_CUADRILLA_ORDER','FRAUDE_ETIQUETA','LABEL_COST_NO_ME_FRAUD','LEGACY_MIGRATION',
    'SELF_OFFERS_MANUAL_CARDS','SELLER_BONIFICATIONS_NON_EFFECTIVE_DELIVERIES',
    'SELLER_DIFFERENT_OR_DEFECTIVE_PRODUCT','SELLER_FAILED_RETURNS_FRAUD',
    'SELLER_LONG_TAIL_PRE_SHIPPED','SELLER_SHIPMENT_LABEL_FALSIFICATION','SELLERS_SQUAD_FRAUD')
),
ranked AS (
  SELECT A.*,B.SENTENCE_DATE,
    ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS rn
  FROM pf25 A LEFT JOIN rs B
    ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED
),
mp AS (
  SELECT GCA_ID,
    SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS sf_id
  FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`
)
SELECT EXTRACT(MONTH FROM c.DATE_CREATED) AS mes,
       CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE '%improcedente%' THEN 'imp'
            WHEN LOWER(rdr.STATUS_BACEN) LIKE '%procedente%'  THEN 'proc'
            WHEN LOWER(rdr.STATUS_BACEN) LIKE 'encerrada%'    THEN 'out'
            ELSE 'nao' END AS cat,
       COUNT(DISTINCT c.case_id) AS qtd
FROM ranked c
LEFT JOIN mp m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.sf_id=rdr.CAS_CASE_ID
WHERE c.rn=1
GROUP BY 1,2 ORDER BY 1,2
'@

$rBacDetail = RunBQ @'
SELECT COALESCE(STATUS_BACEN,'Nao analisado') AS s, COUNT(DISTINCT case_id) AS q
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira` GROUP BY 1
'@

# Topicos das mensagens (analise por palavras-chave)
$rTopicos = RunBQ @'
WITH msgs AS (SELECT case_id, LOWER(RECLAMACAO_USUARIO) AS m FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira` WHERE RECLAMACAO_USUARIO IS NOT NULL)
SELECT topico, COUNT(DISTINCT case_id) AS qtd FROM (
  SELECT case_id, 'Saldo / valores retidos' AS topico FROM msgs WHERE m LIKE '%saldo%' OR m LIKE '%valor retido%' OR m LIKE '%reten%'
  UNION ALL SELECT case_id, 'Bloqueio / suspensao de conta' FROM msgs WHERE m LIKE '%bloqueio%' OR m LIKE '%suspens%' OR m LIKE '%conta bloqueada%'
  UNION ALL SELECT case_id, 'Compra garantida' FROM msgs WHERE m LIKE '%compra garantida%'
  UNION ALL SELECT case_id, 'Antecipacao' FROM msgs WHERE m LIKE '%antecipa%'
  UNION ALL SELECT case_id, 'Reembolso / estorno' FROM msgs WHERE m LIKE '%reembolso%' OR m LIKE '%estorno%' OR m LIKE '%devolu%'
  UNION ALL SELECT case_id, 'Falta de justificativa' FROM msgs WHERE m LIKE '%sem justificativa%' OR m LIKE '%sem motivo%' OR m LIKE '%sem explica%'
  UNION ALL SELECT case_id, 'Atendimento / suporte' FROM msgs WHERE m LIKE '%atendimento%' OR m LIKE '%suporte%' OR m LIKE '%protocolo%'
  UNION ALL SELECT case_id, 'Prazo / liberacao' FROM msgs WHERE m LIKE '%prazo%' OR m LIKE '%libera%'
) GROUP BY 1 ORDER BY 2 DESC
'@

# SLA: casos sem consulta previa - total e por mes
$rSlaConsulta = RunBQ @'
SELECT
  CASE WHEN qtde_consultas = 0 THEN 'Sem consulta previa' ELSE 'Com consulta previa' END AS tipo,
  COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1
'@

$rSlaConsultaMes = RunBQ @'
SELECT mes_criacao AS mes,
  CASE WHEN qtde_consultas = 0 THEN 'Sem consulta previa' ELSE 'Com consulta previa' END AS tipo,
  COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,2
'@

$rSlaAcionamento = RunBQ @'
SELECT tempo_acionamento, COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE tempo_acionamento IS NOT NULL AND tempo_acionamento != 'Outros'
GROUP BY 1 ORDER BY 2 DESC
'@

# Comparativo 2025 - procedencia por analisados (mensal)
$rComp25Pct = RunBQ @'
WITH pf25 AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) BETWEEN '2025-01-01' AND '2025-05-31'
    AND TYPE_CASES='cc-commerce' AND GCA_SECOND_SUBTYPE='casos_especiais_bacen'
    AND SUBTYPE_1 IN ("fco-return-consultas-bs","fco-return-revision-manual-bs","fco-return-revision-manual-lt","fco-return-consultas-lt","fco-post-shipped-revision-manual-bs","fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs","fco-pre-shipped-consultas-lt","fraud_seller_user","fraud_seller_user_bof","fraude_com_oferta","fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs","fco-pre-shipped-revision-manual-bs","guardianes_seller_post_shipped","guardianes_seller_return","quadrilha_autofertas_consultas","assoc_ilicita_consultas","fraude_user_bof")
    AND (DERIVACAO_CX IS NULL OR DERIVACAO_CX!='INCORRECT') AND (REASON IS NULL OR REASON!='DERIVATION_TO_ANOTHER_SECTOR')
),
rs AS (SELECT * FROM `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW` WHERE INFRACTION_TYPE IN ('AUTO_OFERTAS_BUYER','AUTO_OFERTAS_SELLER','BOF_BIG_SELLERS','BUYER_PROTECTION_PROGRAM','CUENTA_LARANJA','DANGEROUS_CROSSING','EMPTY_BOX_SELLER_FRAUD','FRAUDE_CUADRILLA','FRAUDE_CUADRILLA_ORDER','FRAUDE_ETIQUETA','LABEL_COST_NO_ME_FRAUD','LEGACY_MIGRATION','SELF_OFFERS_MANUAL_CARDS','SELLER_BONIFICATIONS_NON_EFFECTIVE_DELIVERIES','SELLER_DIFFERENT_OR_DEFECTIVE_PRODUCT','SELLER_FAILED_RETURNS_FRAUD','SELLER_LONG_TAIL_PRE_SHIPPED','SELLER_SHIPMENT_LABEL_FALSIFICATION','SELLERS_SQUAD_FRAUD')),
ranked AS (SELECT A.*,B.SENTENCE_DATE,ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS rn FROM pf25 A LEFT JOIN rs B ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED),
mp AS (SELECT GCA_ID,SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS sf_id FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`)
SELECT
  COUNT(DISTINCT c.case_id) AS total,
  COUNT(DISTINCT CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE 'encerrada%' THEN c.case_id END) AS analisados,
  COUNT(DISTINCT CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE '%procedente%' AND LOWER(rdr.STATUS_BACEN) NOT LIKE '%improcedente%' THEN c.case_id END) AS proc
FROM ranked c
LEFT JOIN mp m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.sf_id=rdr.CAS_CASE_ID
WHERE c.rn=1
'@

Log "Dados recebidos. Processando..."

# ================================================================
# STEP 3 - Processar dados
# ================================================================

# --- Resolucao + cartao ---
$resMap  = @{Manteve=@(0,0,0,0,0);Retirou=@(0,0,0,0,0);Outros=@(0,0,0,0,0);Sem=@(0,0,0,0,0)}
$reabMap = @{amarelo=@(0,0,0,0,0);vermelho=@(0,0,0,0,0);verde=@(0,0,0,0,0);nulo=@(0,0,0,0,0)}
$mantMap = @{amarelo=@(0,0,0,0,0);vermelho=@(0,0,0,0,0);verde=@(0,0,0,0,0);nulo=@(0,0,0,0,0)}
foreach ($r in $rRes) {
    $m = [int]$r.mes - 1; if ($m -lt 0 -or $m -gt 4) { continue }
    $q = [int]$r.qtd
    # Normaliza resolution (tabela pode ter 'Manteve' ou 'Manteve cartao')
    $res = if     ($r.resolution -like 'Manteve*') {'Manteve'}
           elseif ($r.resolution -like 'Retirou*') {'Retirou'}
           elseif ($r.resolution -like 'Outro*')   {'Outros'}
           else                                     {'Sem'}
    $resMap[$res][$m] += $q
    $ctKey = if    ($r.cartao -like '*amarelo*')  {'amarelo'}
             elseif($r.cartao -like '*vermelho*') {'vermelho'}
             elseif($r.cartao -like '*verde*')    {'verde'}
             else                                 {'nulo'}
    if ($res -eq 'Retirou') { $reabMap[$ctKey][$m] += $q }
    if ($res -eq 'Manteve') { $mantMap[$ctKey][$m] += $q }
}

# --- INFRACTION_TYPE top 10 + Outros ---
$infAll = @{}
foreach ($r in $rInf) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if(-not $infAll.ContainsKey($r.inf)){$infAll[$r.inf]=@(0,0,0,0,0)}
    $infAll[$r.inf][$m] += [int]$r.qtd
}
$infTop = $infAll.GetEnumerator() |
    Sort-Object {($_.Value | Measure-Object -Sum).Sum} -Descending |
    Select-Object -First 10
$infDict = @{}
foreach($e in $infTop){ $infDict[$e.Key]=$e.Value }
$outros5 = @(0,0,0,0,0)
foreach($e in $infAll.GetEnumerator()){
    if(-not $infDict.ContainsKey($e.Key)){
        for($i=0;$i-lt5;$i++){$outros5[$i]+=$e.Value[$i]}
    }
}
$infDict['Outros']=$outros5

# --- DETALLE_REGLAS ---
$regAll = @{}
foreach ($r in $rReg) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if(-not $regAll.ContainsKey($r.regra)){$regAll[$r.regra]=@(0,0,0,0,0)}
    $regAll[$r.regra][$m] += [int]$r.qtd
}

# --- SUBTYPE_1 ---
$subAll = @{}
foreach ($r in $rSub) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if(-not $subAll.ContainsKey($r.sub)){$subAll[$r.sub]=@(0,0,0,0,0)}
    $subAll[$r.sub][$m] += [int]$r.qtd
}

# --- STATUS_BACEN 2026 ---
$bacMap=@{nao=@(0,0,0,0,0);imp=@(0,0,0,0,0);proc=@(0,0,0,0,0);out=@(0,0,0,0,0)}
foreach ($r in $rBac) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if($bacMap.ContainsKey($r.cat)){$bacMap[$r.cat][$m]+=[int]$r.qtd}
}

# --- SLA ---
$slaB  = @{'menos de 0 dias'=@(0,0,0,0,0);'mais de 6 dias'=@(0,0,0,0,0);'3 a 5 dias'=@(0,0,0,0,0);'1 a 3 dias'=@(0,0,0,0,0)}
$slaC  = @{'mais de 6 dias'=@(0,0,0,0,0);'3 a 5 dias'=@(0,0,0,0,0);'1 a 3 dias'=@(0,0,0,0,0)}
$slaBc = @{'mais de 6 dias'=@(0,0,0,0,0);'3 a 5 dias'=@(0,0,0,0,0);'1 a 3 dias'=@(0,0,0,0,0)}
foreach ($r in $rSla) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}; $q=[int]$r.qtd
    if($slaB.ContainsKey($r.ab)){$slaB[$r.ab][$m]+=$q}
    if($slaC.ContainsKey($r.ac)){$slaC[$r.ac][$m]+=$q}
    if($slaBc.ContainsKey($r.abc)){$slaBc[$r.abc][$m]+=$q}
}

# --- Comparativo 2025 ---
$c25=@{nao=@(0,0,0,0,0);imp=@(0,0,0,0,0);proc=@(0,0,0,0,0);tot=@(0,0,0,0,0)}
foreach ($r in $rComp) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if($c25.ContainsKey($r.cat)){$c25[$r.cat][$m]+=[int]$r.qtd}
    $c25['tot'][$m]+=[int]$r.qtd
}
$c25bac=@(0,0,0,0,0)
foreach ($r in $rComp) {
    $m=[int]$r.mes-1; if($m -lt 0 -or $m -gt 4){continue}
    if($r.cat -ne 'nao'){$c25bac[$m]+=[int]$r.qtd}
}

# --- KPIs BACEN detalhe ---
$kpiNconcl=0;$kpiCancel=0;$kpiNreg=0
foreach($r in $rBacDetail){
    $s=$r.s.ToLower(); $q=[int]$r.q
    if($s -like '*conclusi*'){$kpiNconcl+=$q}
    elseif($s -like '*cancelad*'){$kpiCancel+=$q}
    elseif($s -like '*regulad*' -and $s -notlike '*impro*' -and $s -notlike '*proced*'){$kpiNreg+=$q}
}

# --- Strings JS ---
$msgsJs = ($rMsgs | ForEach-Object {
    $id  = Esc $_.id; $c = Esc $_.caso; $mg = Esc $_.msg
    "{id:'$id',caso:'$c',msg:'$mg'}"
}) -join ','

$melhJs = ($rMelh | ForEach-Object {
    $id = Esc $_.id; $c = Esc $_.caso; $ml = Esc $_.mel
    "{id:'$id',caso:'$c',mel:'$ml'}"
}) -join ','

$regraOpts = ($regAll.Keys | Sort-Object |
    ForEach-Object { '<option>' + [System.Web.HttpUtility]::HtmlEncode($_) + '</option>' }) -join ''

$equipeOpts = ($infDict.Keys | Where-Object {$_ -ne 'Outros'} | Sort-Object |
    ForEach-Object { '<option>' + [System.Web.HttpUtility]::HtmlEncode($_) + '</option>' }) -join ''

$causOpts = ($subAll.Keys |
    Sort-Object {($subAll[$_]|Measure-Object -Sum).Sum} -Descending |
    Select-Object -First 15 |
    ForEach-Object { '<option>' + [System.Web.HttpUtility]::HtmlEncode($_) + '</option>' }) -join ''

$updated = Get-Date -f 'dd/MM/yyyy HH:mm'

# ---- Processar novos dados (deve ser antes de $jsData) ----

# Topicos mensagens
$topicoLabelsArr = @(); $topicoValsArr = @()
foreach ($r in $rTopicos) {
    $topicoLabelsArr += "'" + (Esc $r.topico) + "'"
    $topicoValsArr   += [int]$r.qtd
}
$topicoTot    = if($rMsgs){($rMsgs | Measure-Object).Count}else{1}
$topicoLabels = $topicoLabelsArr -join ','
$topicoVals   = $topicoValsArr   -join ','

# SLA consulta previa - total
$slaConsultaDict = @{'Sem consulta previa'=0;'Com consulta previa'=0}
foreach ($r in $rSlaConsulta) { if($slaConsultaDict.ContainsKey($r.tipo)){$slaConsultaDict[$r.tipo]=[int]$r.qtd} }

# SLA consulta previa - por mes
$slaConsultaSem = @(0,0,0,0,0)
$slaConsultaCom = @(0,0,0,0,0)
foreach ($r in $rSlaConsultaMes) {
    $m = [int]$r.mes - 1; if($m -lt 0 -or $m -gt 4){continue}
    if($r.tipo -eq 'Sem consulta previa'){$slaConsultaSem[$m]=[int]$r.qtd}
    else{$slaConsultaCom[$m]=[int]$r.qtd}
}

# SLA acionamento
$slaAcionDict = @{}
foreach ($r in $rSlaAcionamento) {
    if ($r.tempo_acionamento) { $slaAcionDict[$r.tempo_acionamento]=[int]$r.qtd }
}

# Comparativo % procedencia/analisados
$comp25Anal    = if($rComp25Pct -and $rComp25Pct.Count -gt 0){[int]$rComp25Pct[0].analisados}else{0}
$comp25ProcPct = if($comp25Anal -gt 0){[math]::Round([int]$rComp25Pct[0].proc/$comp25Anal*100,1)}else{0}
$comp26Bac26   = ($bacMap['imp']|Measure-Object -Sum).Sum+($bacMap['proc']|Measure-Object -Sum).Sum+($bacMap['out']|Measure-Object -Sum).Sum
$comp26Anal    = $comp26Bac26
$comp26ProcPct = if($comp26Anal -gt 0){[math]::Round(($bacMap['proc']|Measure-Object -Sum).Sum/$comp26Anal*100,1)}else{0}

$jsData = @"
const DR={Manteve:$(J $resMap['Manteve']),Retirou:$(J $resMap['Retirou']),Outros:$(J $resMap['Outros']),Sem:$(J $resMap['Sem'])};
const DREAB=$(JO $reabMap);
const DMANT=$(JO $mantMap);
const DINF=$(JO $infDict);
const DSUB=$(JO $subAll);
const DREG=$(JO $regAll);
const DBACEN={nao:$(J $bacMap['nao']),imp:$(J $bacMap['imp']),proc:$(J $bacMap['proc']),out:$(J $bacMap['out'])};
const DSLA_B=$(JO $slaB);
const DSLA_C=$(JO $slaC);
const DSLA_BC=$(JO $slaBc);
const COMP25_TOT=$(J $c25['tot']);
const COMP25_BAC=$(J $c25bac);
const COMP25_PRO=$(J $c25['proc']);
const COMP25_IMP=$(J $c25['imp']);
const MSGS=[$msgsJs];
const MELH=[$melhJs];
const KPI_NCONCL=$kpiNconcl;
const KPI_CANCEL=$kpiCancel;
const KPI_NREG=$kpiNreg;
const UPDATED='$updated';
const TOPICOS_LABELS=[$topicoLabels];
const TOPICOS_VALS=[$topicoVals];
const TOPICOS_TOT=$topicoTot;
const SLA_CONSULTA=$(JO $slaConsultaDict);
const SLA_CONSULTA_SEM=$(J $slaConsultaSem);
const SLA_CONSULTA_COM=$(J $slaConsultaCom);
const SLA_ACION=$(JO $slaAcionDict);
const COMP25_ANAL=$comp25Anal;
const COMP25_PROC_PCT=$comp25ProcPct;
const COMP26_ANAL=$comp26Anal;
const COMP26_PROC_PCT=$comp26ProcPct;
"@

Log "Gerando HTML..."

# ================================================================
# STEP 4 - Gerar HTML (ASCII-safe template, UTF-8 chars via entities)
# ================================================================
Add-Type -AssemblyName System.Web

$html = [System.Text.StringBuilder]::new()
[void]$html.Append('<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8">')
[void]$html.Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$html.Append('<title>Monitoramento BACEN 2026</title>')
[void]$html.Append('<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>')
[void]$html.Append('<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Segoe UI",Arial,sans-serif;background:#f0f2f8;color:#333;font-size:14px}
.tab-bar{display:flex;background:#fff;border-bottom:2px solid #e0e4ef;padding:0 28px;position:sticky;top:0;z-index:200;box-shadow:0 1px 4px rgba(0,0,0,.08)}
.tab{padding:14px 22px;cursor:pointer;font-size:13px;font-weight:500;color:#888;border-bottom:3px solid transparent;margin-bottom:-2px;transition:all .15s;white-space:nowrap}
.tab.active{color:#3a5bdb;border-bottom-color:#3a5bdb}.tab:hover{color:#3a5bdb}
.gf{background:#fff;border-bottom:1px solid #e0e4ef;padding:8px 28px;display:flex;gap:8px;flex-wrap:wrap;align-items:center;position:sticky;top:49px;z-index:199;box-shadow:0 1px 3px rgba(0,0,0,.04)}
.gf label{font-size:11px;color:#888;font-weight:600;white-space:nowrap}
select.fs{padding:5px 9px;border:1.5px solid #d0d5e8;border-radius:7px;font-size:12px;background:#fff;color:#444;cursor:pointer;outline:none;max-width:180px}
select.fs:focus{border-color:#3a5bdb}
button.fb{padding:5px 11px;border-radius:7px;background:#f0f2f8;border:1.5px solid #d0d5e8;font-size:12px;color:#666;cursor:pointer}
button.fb:hover{background:#e0e4ef}
.sep{width:1px;height:18px;background:#e0e4ef;margin:0 3px}
.upd{margin-left:auto;font-size:11px;color:#aaa}
.page{display:none;padding:20px 28px}.page.active{display:block}
.pt{font-size:19px;font-weight:600;color:#1a1a2e;margin-bottom:18px;padding-bottom:10px;border-bottom:1px solid #e0e4ef}
.krow{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:22px}
.kpi{background:#fff;border-radius:11px;padding:15px 18px;min-width:110px;flex:1;box-shadow:0 1px 4px rgba(0,0,0,.07);border-top:3px solid #e0e4ef}
.kl{font-size:11px;color:#888;margin-bottom:6px;font-weight:600;text-transform:uppercase;letter-spacing:.4px}
.kv{font-size:28px;font-weight:300;line-height:1}
.kpi.b{border-top-color:#3a5bdb}.kpi.b .kv{color:#3a5bdb}
.kpi.g{border-top-color:#27ae60}.kpi.g .kv{color:#27ae60}
.kpi.r{border-top-color:#e74c3c}.kpi.r .kv{color:#e74c3c}
.kpi.o{border-top-color:#e67e22}.kpi.o .kv{color:#e67e22}
.kpi.p{border-top-color:#8e44ad}.kpi.p .kv{color:#8e44ad}
.kpi.t{border-top-color:#16a085}.kpi.t .kv{color:#16a085}
.crow{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}
.cc{background:#fff;border-radius:11px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);flex:1;min-width:250px}
.cc.w2{flex:0 0 calc(50% - 6px)}.cc.w3{flex:0 0 calc(33.33% - 9px)}
.ct{font-size:13px;font-weight:600;color:#333;margin-bottom:11px}
canvas{max-height:210px}
.tc{background:#fff;border-radius:11px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);margin-bottom:16px;overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:12px}
th{padding:7px 11px;background:#f4f6fa;font-weight:600;color:#555;border-bottom:2px solid #e0e4ef;text-align:left;white-space:nowrap}
td{padding:7px 11px;border-bottom:1px solid #f0f2f8;color:#444;vertical-align:top}
tr:hover td{background:#f8f9fe}
.td-m{max-width:520px;white-space:normal;line-height:1.45}
.td-id{font-weight:500;color:#3a5bdb;white-space:nowrap}
.srch{padding:6px 10px;border:1.5px solid #d0d5e8;border-radius:7px;font-size:12px;width:240px;outline:none;margin-bottom:9px}
.srch:focus{border-color:#3a5bdb}
.pager{display:flex;gap:5px;align-items:center;margin-top:9px;justify-content:flex-end;font-size:12px;color:#888}
.pager button{padding:3px 9px;border:1.5px solid #d0d5e8;border-radius:6px;background:#fff;cursor:pointer;font-size:12px}
.pager button:disabled{opacity:.4;cursor:default}
.up{color:#e74c3c;font-weight:600}.dn{color:#27ae60;font-weight:600}
.ksub{font-size:11px;color:#aaa;margin-top:4px}
</style></head><body>')

# Tab bar
[void]$html.Append('<div class="tab-bar">
  <div class="tab active" onclick="showTab(''casos'',this)">Vis&#227;o Casos</div>
  <div class="tab" onclick="showTab(''bacen'',this)">Vis&#227;o BACEN</div>
  <div class="tab" onclick="showTab(''sla'',this)">Vis&#227;o SLA</div>
  <div class="tab" onclick="showTab(''comp'',this)">Comparativo 2025 vs 2026</div>
</div>')

# Global filters
[void]$html.Append('<div class="gf">
  <label>Trimestre</label>
  <select class="fs" id="g-tri" onchange="onTri()">
    <option value="">Todos</option>
    <option value="Q1">Q1 (Jan-Mar)</option>
    <option value="Q2">Q2 (Abr-Mai)</option>
  </select>
  <div class="sep"></div>
  <label>M&#234;s</label>
  <select class="fs" id="g-mes" onchange="onMes()">
    <option value="">Todos</option>
    <option value="1">Janeiro</option><option value="2">Fevereiro</option>
    <option value="3">Mar&#231;o</option><option value="4">Abril</option>
    <option value="5">Maio</option>
  </select>
  <div class="sep"></div>
  <label>Regra</label>
  <select class="fs" id="g-reg" onchange="applyAll()"><option value="">Todas</option>' + $regraOpts + '</select>
  <div class="sep"></div>
  <label>Casu&#237;stica</label>
  <select class="fs" id="g-cau" onchange="applyAll()"><option value="">Todas</option>' + $causOpts + '</select>
  <div class="sep"></div>
  <label>Cart&#227;o</label>
  <select class="fs" id="g-ct" onchange="applyAll()">
    <option value="">Todos</option>
    <option value="amarelo">Cart&#227;o amarelo</option>
    <option value="vermelho">Cart&#227;o vermelho</option>
    <option value="verde">Cart&#227;o verde</option>
  </select>
  <div class="sep"></div>
  <label>Equipe</label>
  <select class="fs" id="g-eq" onchange="applyAll()"><option value="">Todas</option>' + $equipeOpts + '</select>
  <div class="sep"></div>
  <button class="fb" onclick="resetAll()">&#x2715; Limpar</button>
  <span class="upd">Atualizado em: <span id="lbl-upd"></span></span>
  <button class="fb" onclick="location.reload(true)" style="margin-left:8px;background:#3a5bdb;color:#fff;border-color:#3a5bdb;font-weight:600">&#8635; Atualizar</button>
</div>')

# Pages HTML
[void]$html.Append('
<div class="page active" id="page-casos">
  <div class="pt">Vis&#227;o Casos</div>
  <div class="krow">
    <div class="kpi">  <div class="kl">Total de Casos</div><div class="kv" id="k-tot"></div></div>
    <div class="kpi r"><div class="kl">Abertos</div><div class="kv" id="k-sem"></div></div>
    <div class="kpi b"><div class="kl">Fechados</div><div class="kv" id="k-fec"></div></div>
    <div class="kpi g"><div class="kl">Reabilitados</div><div class="kv" id="k-rea"></div></div>
    <div class="kpi o"><div class="kl">Manteve cart&#227;o</div><div class="kv" id="k-man"></div></div>
    <div class="kpi p"><div class="kl">Outros</div><div class="kv" id="k-out"></div></div>
  </div>
  <div class="crow">
    <div class="cc w3"><div class="ct">Dimens&#227;o por fechamento</div><canvas id="c-fec"></canvas></div>
    <div class="cc w3"><div class="ct">Evolu&#231;&#227;o Mensal</div><canvas id="c-evo"></canvas></div>
    <div class="cc w3"><div class="ct">Cart&#227;o reabilitado</div><canvas id="c-cre"></canvas></div>
  </div>
  <div class="crow">
    <div class="cc w3"><div class="ct">Cart&#227;o mantido</div><canvas id="c-cma"></canvas></div>
    <div class="cc w3"><div class="ct">Casos por Equipe (Infra&#231;&#227;o)</div><canvas id="c-equ"></canvas></div>
    <div class="cc w3"><div class="ct">Casos por Casu&#237;stica</div><canvas id="c-cau"></canvas></div>
  </div>
  <div class="crow"><div class="cc" style="flex:1">
    <div class="ct">Casos por Regra - todas</div>
    <div style="overflow-y:auto;max-height:540px"><canvas id="c-reg-c"></canvas></div>
  </div></div>
</div>

<div class="page" id="page-bacen">
  <div class="pt">Vis&#227;o BACEN</div>
  <div class="krow">
    <div class="kpi">  <div class="kl">N&#227;o analisados</div><div class="kv" id="kb-nao"></div><div class="ksub" id="kb-nao-pct"></div></div>
    <div class="kpi g"><div class="kl">Proced&#234;ncia</div><div class="kv" id="kb-pro"></div><div class="ksub" id="kb-pro-pct"></div></div>
    <div class="kpi r"><div class="kl">Improced&#234;ncia</div><div class="kv" id="kb-imp"></div><div class="ksub" id="kb-imp-pct"></div></div>
    <div class="kpi o"><div class="kl">N&#227;o conclusiva</div><div class="kv" id="kb-ncl"></div><div class="ksub" id="kb-ncl-pct"></div></div>
    <div class="kpi p"><div class="kl">Cancelada</div><div class="kv" id="kb-can"></div><div class="ksub" id="kb-can-pct"></div></div>
    <div class="kpi t"><div class="kl">N&#227;o regulada</div><div class="kv" id="kb-nrg"></div><div class="ksub" id="kb-nrg-pct"></div></div>
  </div>
  <div class="krow">
    <div class="kpi b"><div class="kl">% Proced. / Analisados BACEN</div><div class="kv" id="kb-pct-proc"></div><div class="ksub" id="kb-pct-proc-sub"></div></div>
    <div class="kpi r"><div class="kl">% Improced. / Analisados BACEN</div><div class="kv" id="kb-pct-imp"></div><div class="ksub" id="kb-pct-imp-sub"></div></div>
    <div class="kpi">  <div class="kl">Total analisados BACEN</div><div class="kv" id="kb-anal"></div><div class="ksub" id="kb-anal-pct"></div></div>
    <div class="kpi p"><div class="kl">Melhorias BACEN</div><div class="kv" id="kb-melh"></div><div class="ksub" id="kb-melh-sub"></div></div>
  </div>
  <div class="crow">
    <div class="cc w2"><div class="ct">Decis&#227;o an&#225;lise BACEN</div><canvas id="c-dec"></canvas></div>
    <div class="cc w2"><div class="ct">% Decis&#245;es / analisados</div><canvas id="c-pca"></canvas></div>
  </div>
  <div class="crow">
    <div class="cc w2"><div class="ct">Casos por an&#225;lise BACEN</div><canvas id="c-csb"></canvas></div>
    <div class="cc w2"><div class="ct">% Decis&#245;es / total</div><canvas id="c-pct"></canvas></div>
  </div>
  <div class="crow"><div class="cc" style="flex:1">
    <div class="ct">Casos por Regra - todas</div>
    <div style="overflow-y:auto;max-height:540px"><canvas id="c-reg-b"></canvas></div>
  </div></div>
  <div class="crow"><div class="cc" style="flex:1">
    <div class="ct">Principais temas nas mensagens dos Sellers</div>
    <canvas id="c-topicos"></canvas>
  </div></div>

  <div class="tc">
    <div class="ct" style="margin-bottom:10px">Mensagem do Seller</div>
    <input class="srch" id="srch" placeholder="Buscar Id Seller, caso ou mensagem..." oninput="filterMsgs()">
    <table><thead><tr><th>#</th><th>Id Seller</th><th>Caso</th><th>Mensagem do Seller</th></tr></thead>
    <tbody id="tb-msg"></tbody></table>
    <div class="pager"><span id="pg-info"></span>
      <button id="pg-prev" onclick="chPg(-1)">&#8249;</button>
      <button id="pg-next" onclick="chPg(1)">&#8250;</button></div>
  </div>
  <div class="tc">
    <div class="ct" style="margin-bottom:10px">Melhorias BACEN</div>
    <table><thead><tr><th>#</th><th>Id Seller</th><th>Caso</th><th>Melhoria</th></tr></thead>
    <tbody id="tb-mel"></tbody></table>
  </div>
</div>

<div class="page" id="page-sla">
  <div class="pt">Vis&#227;o SLA</div>
  <div class="crow">
    <div class="cc w2"><div class="ct">Casos sem consulta pr&#233;via ao BACEN</div><canvas id="c-sla-sem"></canvas></div>
    <div class="cc w2"><div class="ct">Tempo de acionamento (restri&#231;&#227;o &#8594; caso)</div><canvas id="c-sla-acion"></canvas></div>
  </div>
  <div class="crow"><div class="cc" style="flex:1">
    <div class="ct">Consulta pr&#233;via por m&#234;s</div>
    <canvas id="c-sla-sem-mes"></canvas>
  </div></div>
  <div class="crow"><div class="cc" style="flex:1"><div class="ct">Acionamento entre restri&#231;&#227;o e caso de BACEN</div><canvas id="c-sb"></canvas></div></div>
  <div class="crow"><div class="cc" style="flex:1"><div class="ct">Acionamento entre restri&#231;&#227;o e caso de Consultas</div><canvas id="c-sc"></canvas></div></div>
  <div class="crow"><div class="cc" style="flex:1"><div class="ct">Acionamento entre consultas e BACEN</div><canvas id="c-sbc"></canvas></div></div>
</div>

<div class="page" id="page-comp">
  <div class="pt">Comparativo Jan-Mai 2025 vs 2026</div>
  <div class="crow">
    <div class="cc w2"><div class="ct">Total de casos por m&#234;s</div><canvas id="cc-t"></canvas></div>
    <div class="cc w2"><div class="ct">Recebidos pelo BACEN</div><canvas id="cc-b"></canvas></div>
  </div>
  <div class="crow">
    <div class="cc w2"><div class="ct">Proced&#234;ncias por m&#234;s</div><canvas id="cc-p"></canvas></div>
    <div class="cc w2"><div class="ct">Improced&#234;ncias por m&#234;s</div><canvas id="cc-i"></canvas></div>
  </div>
  <div class="crow">
    <div class="cc w2"><div class="ct">% Proced&#234;ncia / Analisados BACEN por m&#234;s</div><canvas id="cc-pct-proc"></canvas></div>
    <div class="cc w2"><div class="ct">% Improced&#234;ncia / Analisados BACEN por m&#234;s</div><canvas id="cc-pct-imp"></canvas></div>
  </div>
  <div class="tc">
    <div class="ct" style="margin-bottom:10px">Resumo comparativo</div>
    <table><thead><tr><th>M&#233;trica</th><th>2026</th><th>2025</th><th>Varia&#231;&#227;o</th></tr></thead>
    <tbody id="tb-comp"></tbody></table>
  </div>
</div>')

# JavaScript
[void]$html.Append('<script>')
[void]$html.Append($jsData)
[void]$html.Append('
const MESES=["Jan","Fev","Mar","Abr","Mai"];
const ALL=[0,1,2,3,4];
const C={az:"#4472C4",or:"#ED7D31",ro:"#7030A0",ve:"#70AD47",am:"#FFC000",ci:"#A0A0A0",te:"#00B0A0",azl:"rgba(68,114,196,.35)"};
const CH={};
const GF={tri:"",mes:"",reg:"",cau:"",ct:"",eq:""};
document.getElementById("lbl-upd").textContent=UPDATED;

function idx(){
  if(GF.tri==="Q1")return[0,1,2];
  if(GF.tri==="Q2")return[3,4];
  if(GF.mes)return[parseInt(GF.mes)-1];
  return ALL;
}
function sm(a,ii){return ii.reduce((s,i)=>s+(a[i]||0),0);}

function mkBar(id,ds,lb,st,pct){
  if(CH[id])CH[id].destroy();
  CH[id]=new Chart(document.getElementById(id),{type:"bar",data:{labels:lb||MESES,datasets:ds},
    options:{responsive:true,maintainAspectRatio:true,
      plugins:{legend:{position:"top",labels:{boxWidth:10,font:{size:10}}}},
      scales:{x:{stacked:!!st,grid:{display:false}},y:{stacked:!!st,beginAtZero:true,ticks:pct?{callback:v=>v+"%"}:{}}}}});
}
function mkLine(id,ds,lb){
  if(CH[id])CH[id].destroy();
  CH[id]=new Chart(document.getElementById(id),{type:"line",data:{labels:lb||MESES,datasets:ds},
    options:{responsive:true,maintainAspectRatio:true,
      plugins:{legend:{position:"top",labels:{boxWidth:10,font:{size:10}}}},
      scales:{x:{grid:{display:false}},y:{beginAtZero:true}}}});
}
function mkHBar(id,obj,ii){
  if(CH[id])CH[id].destroy();
  const ent=Object.entries(obj).map(([k,v])=>({k,tot:ii.reduce((a,i)=>a+(v[i]||0),0),v}))
    .filter(e=>e.tot>0).sort((a,b)=>b.tot-a.tot);
  const lbl=ent.map(e=>e.k);
  const mc=[C.az,C.or,C.ro,C.ve,C.am];
  const ds=ii.map((mi,j)=>({label:MESES[mi],data:ent.map(e=>e.v[mi]||0),backgroundColor:mc[j%5]}));
  const h=Math.max(280,lbl.length*25);
  const cv=document.getElementById(id);cv.style.height=h+"px";cv.height=h;
  CH[id]=new Chart(cv,{type:"bar",data:{labels:lbl,datasets:ds},
    options:{indexAxis:"y",responsive:true,maintainAspectRatio:false,
      plugins:{legend:{position:"top",labels:{boxWidth:10,font:{size:10}}}},
      scales:{x:{stacked:true,beginAtZero:true,grid:{display:false}},y:{stacked:true,ticks:{font:{size:11}}}}}});
}
function mkGrp(id,d26,d25){
  if(CH[id])CH[id].destroy();
  CH[id]=new Chart(document.getElementById(id),{type:"bar",
    data:{labels:MESES,datasets:[{label:"2026",data:d26,backgroundColor:C.az},{label:"2025",data:d25,backgroundColor:C.azl}]},
    options:{responsive:true,maintainAspectRatio:true,
      plugins:{legend:{position:"top",labels:{boxWidth:10,font:{size:10}}}},
      scales:{x:{grid:{display:false}},y:{beginAtZero:true}}}});
}

function renderCasos(ii){
  const lb=ii.length<5?ii.map(i=>MESES[i]):MESES;
  const tot=ii.reduce((a,i)=>a+Object.values(DR).reduce((b,v)=>b+(v[i]||0),0),0);
  document.getElementById("k-tot").textContent=tot;
  document.getElementById("k-sem").textContent=sm(DR.Sem,ii);
  document.getElementById("k-fec").textContent=tot-sm(DR.Sem,ii);
  document.getElementById("k-rea").textContent=sm(DR.Retirou,ii);
  document.getElementById("k-man").textContent=sm(DR.Manteve,ii);
  document.getElementById("k-out").textContent=sm(DR.Outros,ii);
  mkBar("c-fec",[
    {label:"Manteve cartão",data:ii.map(i=>DR.Manteve[i]),backgroundColor:C.az},
    {label:"Retirou restrição",data:ii.map(i=>DR.Retirou[i]),backgroundColor:C.or},
    {label:"Outros",data:ii.map(i=>DR.Outros[i]),backgroundColor:C.ro},
    {label:"Sem analise",data:ii.map(i=>DR.Sem[i]),backgroundColor:C.ve},
  ],lb,true);
  mkLine("c-evo",[{label:"Casos",data:ii.map(i=>Object.values(DR).reduce((a,v)=>a+(v[i]||0),0)),
    borderColor:C.az,backgroundColor:"rgba(68,114,196,.15)",fill:true,tension:.3,pointRadius:4}],lb);
  const ct=GF.ct;
  const rO=ct&&DREAB[ct]?{[ct]:DREAB[ct]}:DREAB;
  mkBar("c-cre",Object.entries(rO).map(([k,v],j)=>({label:"Cartão "+k,data:ii.map(i=>v[i]),backgroundColor:[C.az,C.or,C.ro,C.ve][j%4]})),lb,true);
  const mO=ct&&DMANT[ct]?{[ct]:DMANT[ct]}:DMANT;
  mkBar("c-cma",Object.entries(mO).map(([k,v],j)=>({label:"Cartão "+k,data:ii.map(i=>v[i]),backgroundColor:[C.az,C.or,C.ro,C.ve][j%4]})),lb,true);
  const eq=GF.eq;const eO=eq&&DINF[eq]?{[eq]:DINF[eq]}:DINF;
  mkBar("c-equ",Object.entries(eO).map(([k,v],j)=>({label:k,data:ii.map(i=>v[i]),backgroundColor:[C.az,C.or,C.ro,C.ve,C.am,C.te,C.ci][j%7]})),lb,true);
  const ca=GF.cau;const cO=ca&&DSUB[ca]?{[ca]:DSUB[ca]}:DSUB;
  mkBar("c-cau",Object.entries(cO).map(([k,v],j)=>({label:k,data:ii.map(i=>v[i]),backgroundColor:[C.az,C.or,C.ro,C.ve,C.am,C.ci][j%6]})),lb,true);
  const rg=GF.reg;mkHBar("c-reg-c",rg&&DREG[rg]?{[rg]:DREG[rg]}:DREG,ii);
}

function p1(n,d){return d?+(n/d*100).toFixed(1):0;}
function pf(n,d){return d?(n/d*100).toFixed(1)+"% do total":"";}
function renderBacen(ii){
  const lb=ii.length<5?ii.map(i=>MESES[i]):MESES;
  const nao=sm(DBACEN.nao,ii),proc=sm(DBACEN.proc,ii),imp=sm(DBACEN.imp,ii);
  const anal=sm(DBACEN.imp,ii)+sm(DBACEN.proc,ii)+sm(DBACEN.out,ii);
  const tot=nao+anal;
  // KPIs linha 1 com %
  document.getElementById("kb-nao").textContent=nao;
  document.getElementById("kb-nao-pct").textContent=pf(nao,tot);
  document.getElementById("kb-pro").textContent=proc;
  document.getElementById("kb-pro-pct").textContent=pf(proc,tot)+(anal?" | "+p1(proc,anal)+"% dos analisados":"");
  document.getElementById("kb-imp").textContent=imp;
  document.getElementById("kb-imp-pct").textContent=pf(imp,tot)+(anal?" | "+p1(imp,anal)+"% dos analisados":"");
  document.getElementById("kb-ncl").textContent=KPI_NCONCL;
  document.getElementById("kb-ncl-pct").textContent=pf(KPI_NCONCL,tot);
  document.getElementById("kb-can").textContent=KPI_CANCEL;
  document.getElementById("kb-can-pct").textContent=pf(KPI_CANCEL,tot);
  document.getElementById("kb-nrg").textContent=KPI_NREG;
  document.getElementById("kb-nrg-pct").textContent=pf(KPI_NREG,tot);
  // KPIs linha 2 - percentuais e melhorias
  document.getElementById("kb-pct-proc").textContent=anal?p1(proc,anal).toFixed(1)+"%":"-";
  document.getElementById("kb-pct-proc-sub").textContent=anal?proc+" proc. de "+anal+" analisados":"";
  document.getElementById("kb-pct-imp").textContent=anal?p1(imp,anal).toFixed(1)+"%":"-";
  document.getElementById("kb-pct-imp-sub").textContent=anal?imp+" improc. de "+anal+" analisados":"";
  document.getElementById("kb-anal").textContent=anal;
  document.getElementById("kb-anal-pct").textContent=pf(anal,tot);
  document.getElementById("kb-melh").textContent=MELH.length;
  document.getElementById("kb-melh-sub").textContent=MELH.length+" registros de melhoria";
  const an=ii.map(i=>DBACEN.imp[i]+DBACEN.proc[i]+DBACEN.out[i]);
  const tt=ii.map(i=>DBACEN.nao[i]+DBACEN.imp[i]+DBACEN.proc[i]+DBACEN.out[i]);
  mkBar("c-dec",[
    {label:"Improcedente",data:ii.map(i=>DBACEN.imp[i]),backgroundColor:C.or},
    {label:"Procedente",data:ii.map(i=>DBACEN.proc[i]),backgroundColor:C.az},
    {label:"Outros",data:ii.map(i=>DBACEN.out[i]),backgroundColor:C.ro},
  ],lb,true);
  mkBar("c-pca",[
    {label:"Improcedente",data:ii.map((i,j)=>an[j]?+(DBACEN.imp[i]/an[j]*100).toFixed(1):null),backgroundColor:C.or},
    {label:"Procedente",data:ii.map((i,j)=>an[j]?+(DBACEN.proc[i]/an[j]*100).toFixed(1):null),backgroundColor:C.az},
    {label:"Outros",data:ii.map((i,j)=>an[j]?+(DBACEN.out[i]/an[j]*100).toFixed(1):null),backgroundColor:C.ro},
  ],lb,true,true);
  mkBar("c-csb",[
    {label:"Não analisado",data:ii.map(i=>DBACEN.nao[i]),backgroundColor:C.am},
    {label:"Analisados",data:ii.map((i,j)=>an[j]),backgroundColor:C.az},
  ],lb,true);
  mkBar("c-pct",[
    {label:"Não analisado",data:ii.map((i,j)=>tt[j]?+(DBACEN.nao[i]/tt[j]*100).toFixed(1):0),backgroundColor:C.am},
    {label:"Analisados",data:ii.map((i,j)=>tt[j]?+(an[j]/tt[j]*100).toFixed(1):0),backgroundColor:C.az},
  ],lb,true,true);
  const rg=GF.reg;mkHBar("c-reg-b",rg&&DREG[rg]?{[rg]:DREG[rg]}:DREG,ii);
}

function renderSla(ii){
  const lb=ii.length<5?ii.map(i=>MESES[i]):MESES;
  mkBar("c-sb",[
    {label:"menos de 0 dias",data:ii.map(i=>DSLA_B["menos de 0 dias"][i]),backgroundColor:C.ve},
    {label:"mais de 6 dias",data:ii.map(i=>DSLA_B["mais de 6 dias"][i]),backgroundColor:C.az},
    {label:"3 a 5 dias",data:ii.map(i=>DSLA_B["3 a 5 dias"][i]),backgroundColor:C.or},
    {label:"1 a 3 dias",data:ii.map(i=>DSLA_B["1 a 3 dias"][i]),backgroundColor:C.ro},
  ],lb,true);
  mkBar("c-sc",[
    {label:"mais de 6 dias",data:ii.map(i=>DSLA_C["mais de 6 dias"][i]),backgroundColor:C.az},
    {label:"3 a 5 dias",data:ii.map(i=>DSLA_C["3 a 5 dias"][i]),backgroundColor:C.or},
    {label:"1 a 3 dias",data:ii.map(i=>DSLA_C["1 a 3 dias"][i]),backgroundColor:C.ro},
  ],lb,true);
  mkBar("c-sbc",[
    {label:"mais de 6 dias",data:ii.map(i=>DSLA_BC["mais de 6 dias"][i]),backgroundColor:C.az},
    {label:"3 a 5 dias",data:ii.map(i=>DSLA_BC["3 a 5 dias"][i]),backgroundColor:C.or},
    {label:"1 a 3 dias",data:ii.map(i=>DSLA_BC["1 a 3 dias"][i]),backgroundColor:C.ro},
  ],lb,true);
}

function renderTopicos(){
  if(CH["c-topicos"])CH["c-topicos"].destroy();
  const tot=TOPICOS_TOT||1;
  const pcts=TOPICOS_VALS.map(v=>+(v/tot*100).toFixed(1));
  CH["c-topicos"]=new Chart(document.getElementById("c-topicos"),{
    type:"bar",
    data:{labels:TOPICOS_LABELS,datasets:[{
      label:"Casos (%)",data:pcts,
      backgroundColor:["#4472C4","#ED7D31","#7030A0","#70AD47","#FFC000","#00B0A0","#FF4444","#A0A0A0"],
    }]},
    options:{indexAxis:"y",responsive:true,maintainAspectRatio:true,
      plugins:{legend:{display:false},tooltip:{callbacks:{label:function(c){return " "+c.raw+"% ("+TOPICOS_VALS[c.dataIndex]+" casos)"}}}},
      scales:{x:{beginAtZero:true,ticks:{callback:v=>v+"%"},grid:{display:false}},y:{ticks:{font:{size:11}}}}}
  });
}

function renderSlaExtra(){
  // Donut: com/sem consulta previa
  if(CH["c-sla-sem"])CH["c-sla-sem"].destroy();
  const sem=SLA_CONSULTA["Sem consulta previa"]||0;
  const com=SLA_CONSULTA["Com consulta previa"]||0;
  CH["c-sla-sem"]=new Chart(document.getElementById("c-sla-sem"),{
    type:"doughnut",
    data:{labels:["Sem consulta prévia","Com consulta prévia"],
      datasets:[{data:[sem,com],backgroundColor:["#ED7D31","#4472C4"],borderWidth:2}]},
    options:{responsive:true,maintainAspectRatio:true,
      plugins:{legend:{position:"bottom",labels:{boxWidth:12,font:{size:11}}},
        tooltip:{callbacks:{label:function(c){const t=sem+com;return " "+c.label+": "+c.raw+" ("+((c.raw/t)*100).toFixed(1)+"%)"}}}}}
  });
  // Horizontal bar: tempo de acionamento
  if(CH["c-sla-acion"])CH["c-sla-acion"].destroy();
  const lbl=Object.keys(SLA_ACION);
  const vals=Object.values(SLA_ACION);
  CH["c-sla-acion"]=new Chart(document.getElementById("c-sla-acion"),{
    type:"bar",
    data:{labels:lbl,datasets:[{label:"Casos",data:vals,backgroundColor:"#4472C4"}]},
    options:{indexAxis:"y",responsive:true,maintainAspectRatio:true,
      plugins:{legend:{display:false}},
      scales:{x:{beginAtZero:true,grid:{display:false}},y:{ticks:{font:{size:11}}}}}
  });
  // Stacked bar: consulta previa por mes
  if(CH["c-sla-sem-mes"])CH["c-sla-sem-mes"].destroy();
  const ii=idx();
  const lb2=ii.length<5?ii.map(i=>MESES[i]):MESES;
  CH["c-sla-sem-mes"]=new Chart(document.getElementById("c-sla-sem-mes"),{
    type:"bar",
    data:{labels:lb2,datasets:[
      {label:"Sem consulta prévia",data:ii.map(i=>SLA_CONSULTA_SEM[i]),backgroundColor:"#ED7D31"},
      {label:"Com consulta prévia",data:ii.map(i=>SLA_CONSULTA_COM[i]),backgroundColor:"#4472C4"},
    ]},
    options:{responsive:true,maintainAspectRatio:true,
      plugins:{legend:{position:"top",labels:{boxWidth:11,font:{size:11}}}},
      scales:{x:{stacked:true,grid:{display:false}},y:{stacked:true,beginAtZero:true}}}
  });
}

function renderComp(){
  const t26=ALL.map(i=>Object.values(DR).reduce((a,v)=>a+(v[i]||0),0));
  const b26=ALL.map(i=>DBACEN.imp[i]+DBACEN.proc[i]+DBACEN.out[i]);
  mkGrp("cc-t",t26,COMP25_TOT);mkGrp("cc-b",b26,COMP25_BAC);
  mkGrp("cc-p",ALL.map(i=>DBACEN.proc[i]),COMP25_PRO);
  mkGrp("cc-i",ALL.map(i=>DBACEN.imp[i]),COMP25_IMP);
  function pv(n,d){if(!d)return"n/d";const p=((n-d)/d*100).toFixed(1);return(n>=d?"+":"")+p+"%";}
  function cl(n,d){return n>=d?"up":"dn";}
  const t26s=t26.reduce((a,v)=>a+v,0),b26s=b26.reduce((a,v)=>a+v,0);
  const t25=COMP25_TOT.reduce((a,v)=>a+v,0),b25=COMP25_BAC.reduce((a,v)=>a+v,0);
  const p26=ALL.map(i=>DBACEN.proc[i]).reduce((a,v)=>a+v,0),i26=ALL.map(i=>DBACEN.imp[i]).reduce((a,v)=>a+v,0);
  const p25=COMP25_PRO.reduce((a,v)=>a+v,0),i25=COMP25_IMP.reduce((a,v)=>a+v,0);
  // Graficos % procedencia e improcedencia por mes
  const b26m=ALL.map(i=>DBACEN.imp[i]+DBACEN.proc[i]+DBACEN.out[i]);
  mkGrp("cc-pct-proc",
    ALL.map((i,j)=>b26m[j]?+(DBACEN.proc[i]/b26m[j]*100).toFixed(1):0),
    COMP25_BAC.map((v,i)=>{const a=COMP25_BAC[i];return a?+(COMP25_PRO[i]/a*100).toFixed(1):0})
  );
  mkGrp("cc-pct-imp",
    ALL.map((i,j)=>b26m[j]?+(DBACEN.imp[i]/b26m[j]*100).toFixed(1):0),
    COMP25_BAC.map((v,i)=>{const a=COMP25_BAC[i];return a?+(COMP25_IMP[i]/a*100).toFixed(1):0})
  );

  // Tabela comparativa — linha numerica usa cl()/pv(), linha de % usa calcuo proprio
  function pvPct(a,b){if(!b)return"n/d";const d=a-b;return(d>=0?"+":"")+d.toFixed(1)+" p.p.";}
  document.getElementById("tb-comp").innerHTML=[
    ["Total de casos",t26s,t25,true],
    ["Recebidos do BACEN",b26s,b25,true],
    ["Procedentes",p26,p25,true],
    ["Improcedentes",i26,i25,true],
    ["% Proced. / Analisados BACEN",COMP26_PROC_PCT,COMP25_PROC_PCT,false],
  ].map(([l,a,b,isNum])=>{
    const cls=a>=b?"up":"dn";
    const var_=isNum?pv(a,b):pvPct(a,b);
    const av=isNum?a:a.toFixed(1)+"%";
    const bv=isNum?b:b.toFixed(1)+"%";
    return "<tr><td>"+l+"</td><td><b>"+av+"</b></td><td>"+bv+"</td><td class=\""+cls+"\">"+var_+"</td></tr>";
  }).join("");
}

let fM=MSGS.slice(),pg=1;const PP=15;
function filterMsgs(){
  const q=document.getElementById("srch").value.toLowerCase();
  fM=q?MSGS.filter(m=>m.id.includes(q)||m.caso.includes(q)||m.msg.toLowerCase().includes(q)):MSGS.slice();
  pg=1;rM();
}
function chPg(d){const p=Math.ceil(fM.length/PP)||1;pg=Math.max(1,Math.min(p,pg+d));rM();}
function rM(){
  const p=Math.ceil(fM.length/PP)||1,st=(pg-1)*PP,en=st+PP;
  document.getElementById("tb-msg").innerHTML=fM.slice(st,en).map((m,i)=>
    "<tr><td>"+(st+i+1)+"</td><td class=\"td-id\">"+m.id+"</td>"+
    "<td style=\"font-family:monospace;font-size:11px;white-space:nowrap\">"+m.caso.substring(0,16)+"...</td>"+
    "<td class=\"td-m\">"+m.msg+"</td></tr>"
  ).join("");
  document.getElementById("pg-info").textContent=(st+1)+"-"+Math.min(en,fM.length)+" / "+fM.length;
  document.getElementById("pg-prev").disabled=pg<=1;
  document.getElementById("pg-next").disabled=pg>=p;
}
function rMelh(){
  document.getElementById("tb-mel").innerHTML=MELH.map((m,i)=>
    "<tr><td>"+(i+1)+"</td><td class=\"td-id\">"+m.id+"</td>"+
    "<td style=\"font-family:monospace;font-size:11px;white-space:nowrap\">"+m.caso.substring(0,16)+"...</td>"+
    "<td>"+m.mel+"</td></tr>"
  ).join("");
}
function onTri(){GF.tri=document.getElementById("g-tri").value;if(GF.tri){GF.mes="";document.getElementById("g-mes").value="";}applyAll();}
function onMes(){GF.mes=document.getElementById("g-mes").value;if(GF.mes){GF.tri="";document.getElementById("g-tri").value="";}applyAll();}
function applyAll(){
  GF.tri=document.getElementById("g-tri").value;GF.mes=document.getElementById("g-mes").value;
  GF.reg=document.getElementById("g-reg").value;GF.cau=document.getElementById("g-cau").value;
  GF.ct=document.getElementById("g-ct").value;GF.eq=document.getElementById("g-eq").value;
  const ii=idx();renderCasos(ii);renderBacen(ii);renderSla(ii);
}
function resetAll(){
  ["g-tri","g-mes","g-reg","g-cau","g-ct","g-eq"].forEach(id=>document.getElementById(id).value="");
  Object.keys(GF).forEach(k=>GF[k]="");applyAll();
}
function showTab(id,el){
  document.querySelectorAll(".page").forEach(p=>p.classList.remove("active"));
  document.querySelectorAll(".tab").forEach(t=>t.classList.remove("active"));
  document.getElementById("page-"+id).classList.add("active");el.classList.add("active");
}
renderCasos(ALL);renderBacen(ALL);renderSla(ALL);renderComp();
renderTopicos();renderSlaExtra();
rM();rMelh();
</script></body></html>')

[System.IO.File]::WriteAllText($OUT, $html.ToString(), [System.Text.Encoding]::UTF8)
Log "HTML salvo: $OUT"

# ================================================================
# STEP 4b - Publicar no GitHub Pages
# ================================================================
Log "Publicando no GitHub Pages..."
try {
    Copy-Item $OUT "$REPO\index.html" -Force
    Set-Location $REPO
    git add index.html | Out-Null
    $changes = git status --porcelain
    if ($changes) {
        $date = Get-Date -f 'yyyy-MM-dd HH:mm'
        git commit -m "Dashboard atualizado em $date" | Out-Null
        git push origin main 2>&1 | Out-Null
        Log "GitHub Pages atualizado: https://nayarateixeira-lab.github.io/monitoramento-bacen/"
    } else {
        Log "Nenhuma alteracao para publicar."
    }
} catch {
    Log "AVISO: falha ao publicar no GitHub - $($_.Exception.Message)"
}

# ================================================================
# STEP 5 - Registrar tarefa agendada (se nao existir)
# ================================================================
$taskName = 'Dashboard BACEN - Atualizacao Diaria'
$exists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $exists) {
    Log "Registrando tarefa agendada '$taskName'..."
    $script   = $MyInvocation.MyCommand.Path
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                  -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $trigger  = New-ScheduledTaskTrigger -Daily -At '08:00AM'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'Atualiza dashboard BACEN via BigQuery' `
        -Force | Out-Null
    Log "Tarefa registrada - roda todo dia as 08:00."
} else {
    Log "Tarefa ja existe no agendador."
}

if ($OpenBrowser) { Start-Process $OUT }
Log "Concluido."
