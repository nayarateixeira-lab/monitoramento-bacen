"""
Dashboard BACEN - DataSuite Python 3.13
Credencial BigQuery: credentials_1 (PF_MKT_BQ)
Variavel GITHUB_TOKEN: substituir pelo token gerado no GitHub
"""

import json, base64, datetime, re
from google.cloud import bigquery

# ── CONFIG ──────────────────────────────────────────────────────────
PROJECT      = 'meli-bi-data'
GITHUB_TOKEN = 'COLE_SEU_TOKEN_AQUI'   # <-- substituir
GITHUB_REPO  = 'nayarateixeira-lab/monitoramento-bacen'
GITHUB_FILE  = 'index.html'

# credentials_1 e injetado pelo DataSuite (PF_MKT_BQ)
client = bigquery.Client(project=PROJECT, credentials=credentials_1)

# ── HELPERS ─────────────────────────────────────────────────────────
def run_bq(sql):
    try:
        return [dict(r) for r in client.query(sql).result()]
    except Exception as e:
        print(f"BQ erro: {e}")
        return []

def js_arr(lst):
    return '[' + ','.join(str(v) for v in lst) + ']'

def js_obj(d):
    parts = []
    for k, v in d.items():
        safe_k = k.replace("'", "\\'")
        if isinstance(v, (list, tuple)):
            parts.append(f"'{safe_k}':{js_arr(v)}")
        else:
            parts.append(f"'{safe_k}':{v}")
    return '{' + ','.join(parts) + '}'

def esc(s):
    if not s:
        return ''
    s = str(s).replace('\\', '\\\\').replace("'", "\\'").replace('\n', ' ').replace('\r', '')
    return ''.join(f'\\u{ord(c):04x}' if ord(c) > 127 else c for c in s)

def mes_arr(rows, mes_field, val_field, filter_field=None, filter_val=None):
    a = [0, 0, 0, 0, 0]
    for r in rows:
        if filter_field and str(r.get(filter_field, '')) != filter_val:
            continue
        m = int(r.get(mes_field, 0)) - 1
        if 0 <= m <= 4:
            a[m] += int(r.get(val_field, 0))
    return a

# ── STEP 1: Recriar tabela materializada ────────────────────────────
print("Recriando tabela Monitoramento_Bacen_nteixeira...")
run_bq("""
CREATE OR REPLACE TABLE `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
OPTIONS(expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 20 DAY)) AS
WITH primeiro_filtro AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) >= '2026-01-01'
    AND TYPE_CASES = 'cc-commerce'
    AND GCA_SECOND_SUBTYPE = 'casos_especiais_bacen'
    AND SUBTYPE_1 IN (
      "fco-return-consultas-bs","fco-return-revision-manual-bs","fco-return-revision-manual-lt","fco-return-consultas-lt",
      "fco-post-shipped-revision-manual-bs","fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs",
      "fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt",
      "fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs",
      "fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs","fco-pre-shipped-consultas-lt",
      "fraud_seller_user","fraud_seller_user_bof","fraude_com_oferta",
      "fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs","fco-pre-shipped-revision-manual-bs",
      "guardianes_seller_post_shipped","guardianes_seller_return","quadrilha_autofertas_consultas",
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
  SELECT A.*,B.SENTENCE_DATE,B.INFRACTION_TYPE,B.DETALLE_REGLAS,B.DETECTION_TYPE,B.RULE_RISK_LEVELS,B.SENTENCE_REASON,
    ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS com_restricao
  FROM primeiro_filtro AS A
  LEFT JOIN restricoes_seller AS B ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED
),
mapeamento_ids AS (
  SELECT GCA_ID,
    SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS clean_sf_id
  FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`
)
SELECT DISTINCT
  c.case_id,c.CUST_ID,c.TYPE_CASES,c.GCA_CREATED_MODE,c.SUBTYPE_1,c.admin_case,c.COLA_CX,
  c.GCA_SECOND_SUBTYPE,c.DERIVACAO_CX,c.REASON,
  CAST(c.DATE_CREATED AS DATE) AS DATE_CREATED,
  EXTRACT(MONTH FROM c.DATE_CREATED) AS mes_criacao,
  CAST(c.LAST_UPDATED AS DATE) AS LAST_UPDATED,
  EXTRACT(MONTH FROM c.LAST_UPDATED) AS fechamento_caso,
  rdr.* EXCEPT(CAS_CASE_ID,STATUS_BACEN),
  COALESCE(rdr.STATUS_BACEN,'Nao analisado') AS STATUS_BACEN,
  GREATEST(0,DATE_DIFF(DATE(rdr.INCOMING_DTTM),DATE(c.SENTENCE_DATE),DAY)) AS dias_diff_rdr_incoming_sentence,
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
       ELSE 'mais de 6 dias' END AS agrupamento_bacen_consultas,
  CASE WHEN c.SENTENCE_DATE IS NULL THEN 'Outros'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY)>=365
       THEN CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),YEAR) AS STRING)||' anos'
       WHEN DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY)>=30
       THEN CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),MONTH) AS STRING)||' meses'
       ELSE CAST(DATE_DIFF(CAST(c.DATE_CREATED AS DATE),DATE(c.SENTENCE_DATE),DAY) AS STRING)||' dias'
  END AS tempo_acionamento,
  CAST((SELECT COUNT(DISTINCT case_id) FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
        WHERE CUST_ID=c.CUST_id AND DATE_CREATED>c.SENTENCE_DATE AND DATE_CREATED<c.DATE_CREATED) AS INT64) AS qtde_consultas
FROM casos_com_restricao AS c
LEFT JOIN mapeamento_ids m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.clean_sf_id=rdr.CAS_CASE_ID
WHERE c.com_restricao=1 AND c.DATE_CREATED>='2026-01-01'
""")
print("Tabela criada.")

# ── STEP 2: Queries de dados ─────────────────────────────────────────
print("Buscando dados...")

rRes = run_bq("""
SELECT mes_criacao AS mes, resolution, RULE_RISK_LEVELS AS cartao,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2,3 ORDER BY 1,2
""")

rInf = run_bq("""
SELECT mes_criacao AS mes, IFNULL(INFRACTION_TYPE,'Outros') AS inf,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,3 DESC
""")

rReg = run_bq("""
SELECT mes_criacao AS mes, DETALLE_REGLAS AS regra, COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE DETALLE_REGLAS IS NOT NULL
GROUP BY 1,2 ORDER BY 1,3 DESC
""")

rSub = run_bq("""
SELECT mes_criacao AS mes, SUBTYPE_1 AS sub, COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,3 DESC
""")

rBac = run_bq("""
SELECT mes_criacao AS mes,
  CASE WHEN LOWER(STATUS_BACEN) LIKE '%improcedente%' THEN 'imp'
       WHEN LOWER(STATUS_BACEN) LIKE '%procedente%'  THEN 'proc'
       WHEN LOWER(STATUS_BACEN) LIKE 'encerrada%'    THEN 'out'
       ELSE 'nao' END AS cat,
  COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,2
""")

rSla = run_bq("""
SELECT mes_criacao AS mes, agrupamento_consultas AS ac,
       agrupamento_bacen AS ab, agrupamento_bacen_consultas AS abc,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2,3,4 ORDER BY 1
""")

rMsgs = run_bq("""
SELECT CAST(CUST_ID AS STRING) AS id, case_id AS caso,
       SUBSTR(RECLAMACAO_USUARIO,1,280) AS msg
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE RECLAMACAO_USUARIO IS NOT NULL AND RECLAMACAO_USUARIO != ''
ORDER BY DATE_CREATED DESC LIMIT 200
""")

rMelh = run_bq("""
SELECT CAST(CUST_ID AS STRING) AS id, case_id AS caso, MELHORIA_BACEN AS mel
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE MELHORIA_BACEN IS NOT NULL AND MELHORIA_BACEN != ''
ORDER BY DATE_CREATED DESC LIMIT 100
""")

rTopicos = run_bq("""
WITH msgs AS (SELECT case_id, LOWER(RECLAMACAO_USUARIO) AS m
              FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
              WHERE RECLAMACAO_USUARIO IS NOT NULL)
SELECT topico, COUNT(DISTINCT case_id) AS qtd FROM (
  SELECT case_id,'Saldo / valores retidos' AS topico FROM msgs WHERE m LIKE '%saldo%' OR m LIKE '%valor retido%' OR m LIKE '%reten%'
  UNION ALL SELECT case_id,'Bloqueio / suspensao de conta' FROM msgs WHERE m LIKE '%bloqueio%' OR m LIKE '%suspens%'
  UNION ALL SELECT case_id,'Compra garantida' FROM msgs WHERE m LIKE '%compra garantida%'
  UNION ALL SELECT case_id,'Antecipacao' FROM msgs WHERE m LIKE '%antecipa%'
  UNION ALL SELECT case_id,'Reembolso / estorno' FROM msgs WHERE m LIKE '%reembolso%' OR m LIKE '%estorno%' OR m LIKE '%devolu%'
  UNION ALL SELECT case_id,'Falta de justificativa' FROM msgs WHERE m LIKE '%sem justificativa%' OR m LIKE '%sem motivo%'
  UNION ALL SELECT case_id,'Atendimento / suporte' FROM msgs WHERE m LIKE '%atendimento%' OR m LIKE '%suporte%'
  UNION ALL SELECT case_id,'Prazo / liberacao' FROM msgs WHERE m LIKE '%prazo%' OR m LIKE '%libera%'
) GROUP BY 1 ORDER BY 2 DESC
""")

rSlaConsulta = run_bq("""
SELECT CASE WHEN qtde_consultas=0 THEN 'Sem consulta previa' ELSE 'Com consulta previa' END AS tipo,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira` GROUP BY 1
""")

rSlaConsultaMes = run_bq("""
SELECT mes_criacao AS mes,
       CASE WHEN qtde_consultas=0 THEN 'Sem consulta previa' ELSE 'Com consulta previa' END AS tipo,
       COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
GROUP BY 1,2 ORDER BY 1,2
""")

rSlaAcion = run_bq("""
SELECT tempo_acionamento, COUNT(DISTINCT case_id) AS qtd
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira`
WHERE tempo_acionamento IS NOT NULL AND tempo_acionamento != 'Outros'
GROUP BY 1 ORDER BY 2 DESC
""")

rBacDetail = run_bq("""
SELECT COALESCE(STATUS_BACEN,'Nao analisado') AS s, COUNT(DISTINCT case_id) AS q
FROM `meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira` GROUP BY 1
""")

rComp = run_bq("""
WITH pf25 AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) BETWEEN '2025-01-01' AND '2025-05-31'
    AND TYPE_CASES='cc-commerce' AND GCA_SECOND_SUBTYPE='casos_especiais_bacen'
    AND SUBTYPE_1 IN ("fco-return-consultas-bs","fco-return-revision-manual-bs","fco-return-revision-manual-lt","fco-return-consultas-lt","fco-post-shipped-revision-manual-bs","fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs","fco-pre-shipped-consultas-lt","fraud_seller_user","fraud_seller_user_bof","fraude_com_oferta","fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs","fco-pre-shipped-revision-manual-bs","guardianes_seller_post_shipped","guardianes_seller_return","quadrilha_autofertas_consultas","assoc_ilicita_consultas","fraude_user_bof")
    AND (DERIVACAO_CX IS NULL OR DERIVACAO_CX!='INCORRECT') AND (REASON IS NULL OR REASON!='DERIVATION_TO_ANOTHER_SECTOR')
),
rs AS (SELECT * FROM `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW`
       WHERE INFRACTION_TYPE IN ('AUTO_OFERTAS_BUYER','AUTO_OFERTAS_SELLER','BOF_BIG_SELLERS','BUYER_PROTECTION_PROGRAM','CUENTA_LARANJA','DANGEROUS_CROSSING','EMPTY_BOX_SELLER_FRAUD','FRAUDE_CUADRILLA','FRAUDE_CUADRILLA_ORDER','FRAUDE_ETIQUETA','LABEL_COST_NO_ME_FRAUD','LEGACY_MIGRATION','SELF_OFFERS_MANUAL_CARDS','SELLER_BONIFICATIONS_NON_EFFECTIVE_DELIVERIES','SELLER_DIFFERENT_OR_DEFECTIVE_PRODUCT','SELLER_FAILED_RETURNS_FRAUD','SELLER_LONG_TAIL_PRE_SHIPPED','SELLER_SHIPMENT_LABEL_FALSIFICATION','SELLERS_SQUAD_FRAUD')),
ranked AS (SELECT A.*,B.SENTENCE_DATE,ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS rn
           FROM pf25 A LEFT JOIN rs B ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED),
mp AS (SELECT GCA_ID,SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS sf_id
       FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`)
SELECT EXTRACT(MONTH FROM c.DATE_CREATED) AS mes,
       CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE '%improcedente%' THEN 'imp'
            WHEN LOWER(rdr.STATUS_BACEN) LIKE '%procedente%'  THEN 'proc'
            WHEN LOWER(rdr.STATUS_BACEN) LIKE 'encerrada%'    THEN 'out'
            ELSE 'nao' END AS cat,
       COUNT(DISTINCT c.case_id) AS qtd
FROM ranked c
LEFT JOIN mp m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.sf_id=rdr.CAS_CASE_ID
WHERE c.rn=1 GROUP BY 1,2 ORDER BY 1,2
""")

rComp25Pct = run_bq("""
WITH pf25 AS (
  SELECT * FROM `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS`
  WHERE DATE(DATE_CREATED) BETWEEN '2025-01-01' AND '2025-05-31'
    AND TYPE_CASES='cc-commerce' AND GCA_SECOND_SUBTYPE='casos_especiais_bacen'
    AND SUBTYPE_1 IN ("fco-return-consultas-bs","fco-return-revision-manual-bs","fco-return-revision-manual-lt","fco-return-consultas-lt","fco-post-shipped-revision-manual-bs","fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt,fco-post-shipped-revision-manual-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-bs","fco-post-shipped-consultas-bs","fco-post-shipped-consultas-lt","fco-post-shipped-revision-manual-bs,fco-post-shipped-consultas-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt,fco-post-shipped-consultas-bs","fco-post-shipped-revision-manual-lt","fco-pre-shipped-consultas-bs","fco-pre-shipped-consultas-lt","fraud_seller_user","fraud_seller_user_bof","fraude_com_oferta","fco-pre-shipped-consultas-bs,fco-pre-shipped-revision-manual-bs","fco-pre-shipped-revision-manual-bs","guardianes_seller_post_shipped","guardianes_seller_return","quadrilha_autofertas_consultas","assoc_ilicita_consultas","fraude_user_bof")
    AND (DERIVACAO_CX IS NULL OR DERIVACAO_CX!='INCORRECT') AND (REASON IS NULL OR REASON!='DERIVATION_TO_ANOTHER_SECTOR')
),
rs AS (SELECT * FROM `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW`
       WHERE INFRACTION_TYPE IN ('AUTO_OFERTAS_BUYER','AUTO_OFERTAS_SELLER','BOF_BIG_SELLERS','BUYER_PROTECTION_PROGRAM','CUENTA_LARANJA','DANGEROUS_CROSSING','EMPTY_BOX_SELLER_FRAUD','FRAUDE_CUADRILLA','FRAUDE_CUADRILLA_ORDER','FRAUDE_ETIQUETA','LABEL_COST_NO_ME_FRAUD','LEGACY_MIGRATION','SELF_OFFERS_MANUAL_CARDS','SELLER_BONIFICATIONS_NON_EFFECTIVE_DELIVERIES','SELLER_DIFFERENT_OR_DEFECTIVE_PRODUCT','SELLER_FAILED_RETURNS_FRAUD','SELLER_LONG_TAIL_PRE_SHIPPED','SELLER_SHIPMENT_LABEL_FALSIFICATION','SELLERS_SQUAD_FRAUD')),
ranked AS (SELECT A.*,B.SENTENCE_DATE,ROW_NUMBER() OVER (PARTITION BY A.case_id ORDER BY B.SENTENCE_DATE DESC) AS rn
           FROM pf25 A LEFT JOIN rs B ON B.USER_ID=CAST(A.CUST_ID AS INT64) AND B.SENTENCE_DATE<=A.DATE_CREATED),
mp AS (SELECT GCA_ID,SAFE_CAST(REPLACE(REPLACE(GCA_SF_ID[SAFE_OFFSET(0)],'[',''),']','') AS INT64) AS sf_id
       FROM `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP`)
SELECT COUNT(DISTINCT c.case_id) AS total,
       COUNT(DISTINCT CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE 'encerrada%' THEN c.case_id END) AS analisados,
       COUNT(DISTINCT CASE WHEN LOWER(rdr.STATUS_BACEN) LIKE '%procedente%' AND LOWER(rdr.STATUS_BACEN) NOT LIKE '%improcedente%' THEN c.case_id END) AS proc
FROM ranked c LEFT JOIN mp m ON c.case_id=m.GCA_ID
LEFT JOIN `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` rdr ON m.sf_id=rdr.CAS_CASE_ID WHERE c.rn=1
""")

print("Dados recebidos. Processando...")

# ── STEP 3: Processar dados ──────────────────────────────────────────

# Resolucao + cartao por mes
res_map  = {k: [0]*5 for k in ['Manteve','Retirou','Outros','Sem']}
reab_map = {k: [0]*5 for k in ['amarelo','vermelho','verde','nulo']}
mant_map = {k: [0]*5 for k in ['amarelo','vermelho','verde','nulo']}
for r in rRes:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    q = int(r['qtd'])
    res = r['resolution'] or ''
    if   res.startswith('Manteve'): k = 'Manteve'
    elif res.startswith('Retirou'): k = 'Retirou'
    elif res.startswith('Outro'):   k = 'Outros'
    else:                           k = 'Sem'
    res_map[k][m] += q
    ct = str(r.get('cartao') or '')
    ctk = 'amarelo' if 'amarelo' in ct else ('vermelho' if 'vermelho' in ct else ('verde' if 'verde' in ct else 'nulo'))
    if k == 'Retirou': reab_map[ctk][m] += q
    if k == 'Manteve': mant_map[ctk][m] += q

# INFRACTION_TYPE top 10 + Outros
inf_all = {}
for r in rInf:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    k = str(r['inf'])
    if k not in inf_all: inf_all[k] = [0]*5
    inf_all[k][m] += int(r['qtd'])
inf_sorted = sorted(inf_all.items(), key=lambda x: sum(x[1]), reverse=True)
inf_dict = dict(inf_sorted[:10])
outros5 = [0]*5
for k, v in inf_all.items():
    if k not in inf_dict:
        for i in range(5): outros5[i] += v[i]
inf_dict['Outros'] = outros5

# DETALLE_REGLAS
reg_all = {}
for r in rReg:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    k = str(r['regra'])
    if k not in reg_all: reg_all[k] = [0]*5
    reg_all[k][m] += int(r['qtd'])

# SUBTYPE_1
sub_all = {}
for r in rSub:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    k = str(r['sub'])
    if k not in sub_all: sub_all[k] = [0]*5
    sub_all[k][m] += int(r['qtd'])

# STATUS_BACEN 2026
bac_map = {k: [0]*5 for k in ['nao','imp','proc','out']}
for r in rBac:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    cat = str(r['cat'])
    if cat in bac_map: bac_map[cat][m] += int(r['qtd'])

# SLA
sla_b  = {'menos de 0 dias':[0]*5,'mais de 6 dias':[0]*5,'3 a 5 dias':[0]*5,'1 a 3 dias':[0]*5}
sla_c  = {'mais de 6 dias':[0]*5,'3 a 5 dias':[0]*5,'1 a 3 dias':[0]*5}
sla_bc = {'mais de 6 dias':[0]*5,'3 a 5 dias':[0]*5,'1 a 3 dias':[0]*5}
for r in rSla:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    q = int(r['qtd'])
    ab, ac, abc = str(r['ab']), str(r['ac']), str(r['abc'])
    if ab  in sla_b:  sla_b[ab][m]   += q
    if ac  in sla_c:  sla_c[ac][m]   += q
    if abc in sla_bc: sla_bc[abc][m] += q

# Comparativo 2025
c25 = {k: [0]*5 for k in ['nao','imp','proc','out','tot']}
for r in rComp:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    cat = str(r['cat'])
    if cat in c25: c25[cat][m] += int(r['qtd'])
    c25['tot'][m] += int(r['qtd'])
c25bac = [c25['imp'][i]+c25['proc'][i]+c25['out'][i] for i in range(5)]

# KPIs BACEN detalhe
kpi_nconcl = kpi_cancel = kpi_nreg = 0
for r in rBacDetail:
    s, q = str(r['s']).lower(), int(r['q'])
    if 'conclusi' in s: kpi_nconcl += q
    elif 'cancelad' in s: kpi_cancel += q
    elif 'regulad' in s and 'impro' not in s and 'proced' not in s: kpi_nreg += q

# % procedencia analisados
comp25_anal = int(rComp25Pct[0]['analisados']) if rComp25Pct else 0
comp25_proc = int(rComp25Pct[0]['proc']) if rComp25Pct else 0
comp25_pct  = round(comp25_proc/comp25_anal*100, 1) if comp25_anal > 0 else 0
comp26_anal = sum(bac_map['imp'])+sum(bac_map['proc'])+sum(bac_map['out'])
comp26_pct  = round(sum(bac_map['proc'])/comp26_anal*100, 1) if comp26_anal > 0 else 0

# Topicos mensagens
topo_labels, topo_vals = [], []
for r in rTopicos:
    topo_labels.append(f"'{esc(str(r['topico']))}'")
    topo_vals.append(int(r['qtd']))
topo_tot = len(rMsgs)

# SLA consulta previa
sla_cons = {'Sem consulta previa': 0, 'Com consulta previa': 0}
for r in rSlaConsulta:
    if r['tipo'] in sla_cons: sla_cons[r['tipo']] = int(r['qtd'])

sla_cons_sem = [0]*5
sla_cons_com = [0]*5
for r in rSlaConsultaMes:
    m = int(r['mes']) - 1
    if not 0 <= m <= 4: continue
    if r['tipo'] == 'Sem consulta previa': sla_cons_sem[m] = int(r['qtd'])
    else: sla_cons_com[m] = int(r['qtd'])

sla_acion = {}
for r in rSlaAcion:
    if r['tempo_acionamento']: sla_acion[str(r['tempo_acionamento'])] = int(r['qtd'])

# Strings JS
msgs_js = ','.join(f"{{id:'{esc(str(r[\"id\"]))}',caso:'{esc(str(r[\"caso\"]))}',msg:'{esc(str(r[\"msg\"]))}'}" for r in rMsgs)
melh_js = ','.join(f"{{id:'{esc(str(r[\"id\"]))}',caso:'{esc(str(r[\"caso\"]))}',mel:'{esc(str(r[\"mel\"]))}'}" for r in rMelh)

# Filter options
regra_opts = ''.join(f'<option>{k}</option>' for k in sorted(reg_all.keys()))
caus_opts  = ''.join(f'<option>{k}</option>' for k, _ in sorted(sub_all.items(), key=lambda x: sum(x[1]), reverse=True)[:15])
equipe_opts= ''.join(f'<option>{k}</option>' for k in sorted(inf_dict.keys()) if k != 'Outros')

updated = datetime.datetime.now().strftime('%d/%m/%Y %H:%M')

js_data = f"""
const DR={{Manteve:{js_arr(res_map['Manteve'])},Retirou:{js_arr(res_map['Retirou'])},Outros:{js_arr(res_map['Outros'])},Sem:{js_arr(res_map['Sem'])}}};
const DREAB={js_obj(reab_map)};
const DMANT={js_obj(mant_map)};
const DINF={js_obj(inf_dict)};
const DSUB={js_obj(sub_all)};
const DREG={js_obj(reg_all)};
const DBACEN={{nao:{js_arr(bac_map['nao'])},imp:{js_arr(bac_map['imp'])},proc:{js_arr(bac_map['proc'])},out:{js_arr(bac_map['out'])}}};
const DSLA_B={js_obj(sla_b)};
const DSLA_C={js_obj(sla_c)};
const DSLA_BC={js_obj(sla_bc)};
const COMP25_TOT={js_arr(c25['tot'])};
const COMP25_BAC={js_arr(c25bac)};
const COMP25_PRO={js_arr(c25['proc'])};
const COMP25_IMP={js_arr(c25['imp'])};
const MSGS=[{msgs_js}];
const MELH=[{melh_js}];
const KPI_NCONCL={kpi_nconcl};
const KPI_CANCEL={kpi_cancel};
const KPI_NREG={kpi_nreg};
const UPDATED='{updated}';
const TOPICOS_LABELS=[{','.join(topo_labels)}];
const TOPICOS_VALS=[{','.join(str(v) for v in topo_vals)}];
const TOPICOS_TOT={topo_tot};
const SLA_CONSULTA={js_obj(sla_cons)};
const SLA_CONSULTA_SEM={js_arr(sla_cons_sem)};
const SLA_CONSULTA_COM={js_arr(sla_cons_com)};
const SLA_ACION={js_obj(sla_acion)};
const COMP25_ANAL={comp25_anal};
const COMP25_PROC_PCT={comp25_pct};
const COMP26_ANAL={comp26_anal};
const COMP26_PROC_PCT={comp26_pct};
"""

print("Gerando HTML...")

# ── STEP 4: Gerar HTML ───────────────────────────────────────────────
# Le o template do HTML atual do GitHub e substitui apenas o bloco de dados JS
import requests as req

headers_gh = {
    'Authorization': f'token {GITHUB_TOKEN}',
    'Accept': 'application/vnd.github.v3+json'
}
url_file = f'https://api.github.com/repos/{GITHUB_REPO}/contents/{GITHUB_FILE}'
r_get = req.get(url_file, headers=headers_gh)
if r_get.status_code != 200:
    raise Exception(f"Erro ao buscar index.html do GitHub: {r_get.text}")

file_info = r_get.json()
sha = file_info['sha']
current_html = base64.b64decode(file_info['content']).decode('utf-8')

# Substitui o bloco JS de dados (entre os marcadores)
import re as re_mod
new_html = re_mod.sub(
    r'(const DR=\{.*?\};\s*\n)(.*?)(const COMP26_PROC_PCT=[\d.]+;)',
    lambda m: js_data.strip() + '\n',
    current_html,
    flags=re_mod.DOTALL
)

# Fallback: se nao encontrou o padrao, substitui tudo entre <script> e renderCasos
if new_html == current_html:
    new_html = re_mod.sub(
        r'(</style></head><body>.*?<script>)(.*?)(const MESES=)',
        lambda m: m.group(1) + '\n' + js_data.strip() + '\n' + m.group(3),
        current_html,
        flags=re_mod.DOTALL
    )

# Push para o GitHub
content_b64 = base64.b64encode(new_html.encode('utf-8')).decode('ascii')
payload = {
    'message': f'Dashboard atualizado via DataSuite em {updated}',
    'content': content_b64,
    'sha': sha
}
r_put = req.put(url_file, headers=headers_gh, json=payload)
if r_put.status_code in (200, 201):
    print(f"GitHub Pages atualizado com sucesso: https://nayarateixeira-lab.github.io/monitoramento-bacen/")
else:
    raise Exception(f"Erro ao publicar no GitHub: {r_put.status_code} - {r_put.text}")

print("Concluido.")
