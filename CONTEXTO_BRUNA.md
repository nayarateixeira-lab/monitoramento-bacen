# Contexto do Projeto — Dashboard Monitoramento BACEN
## Para o Claude da Bruna

---

## O que é o projeto

Dashboard de monitoramento de casos BACEN da equipe PF_MKT (Prevenção de Fraudes - Marketing) 
do Mercado Livre Brasil. É uma página HTML publicada no GitHub Pages que atualiza automaticamente 
com dados do BigQuery.

**Link público do dashboard:**
https://nayarateixeira-lab.github.io/monitoramento-bacen/

---

## Estrutura dos dados (BigQuery)

**Tabela materializada principal (recriada a cada execução):**
```
meli-bi-data.SBOX_PF_MKT.Monitoramento_Bacen_nteixeira
```
Expira em 20 dias. É recriada pelo script antes de cada análise.

**Tabelas fonte:**
- `meli-bi-data.SBOX_PF_MKT.METRICAS_PROJETO_CONSULTAS` — casos de consulta
- `meli-bi-data.WHOWNER.BT_RES_RESTRICTIONS_INFRACTIONS_AND_REVALUATIONS_NW` — restrições dos sellers
- `meli-bi-data.WHOWNER.BT_FRD_GENERAL_CASES_MANUALREW_EXP` — mapeamento case_id → SF_ID
- `meli-bi-data.SBOX_PF_FI.RDR_cases_v2` — dados do BACEN (RDR cases)

**Filtros base da tabela materializada:**
- `TYPE_CASES = 'cc-commerce'`
- `GCA_SECOND_SUBTYPE = 'casos_especiais_bacen'`
- `DATE_CREATED >= '2026-01-01'`
- Lista de SUBTYPE_1 (casuísticas) específicas de fraude
- Exclui `DERIVACAO_CX = 'INCORRECT'` e `REASON = 'DERIVATION_TO_ANOTHER_SECTOR'`

**Campos-chave da tabela materializada:**
- `case_id` — ID do caso
- `CUST_ID` — ID do seller
- `mes_criacao` — mês (1-5 = jan-mai 2026)
- `resolution` — 'Manteve' | 'Retirou' | 'Outros' | 'Sem analise'
- `STATUS_BACEN` — ex: 'Encerrada: reclamação regulada procedente' | 'Nao analisado'
- `RULE_RISK_LEVELS` — 'Cartao verde' | 'Cartao amarelo' | 'Cartao vermelho'
- `INFRACTION_TYPE` — tipo de infração (BOF_BIG_SELLERS, SELLER_LONG_TAIL_PRE_SHIPPED, etc.)
- `DETALLE_REGLAS` — regra específica que gerou a restrição
- `SUBTYPE_1` — casuística do caso
- `agrupamento_bacen` — SLA restrição → BACEN ('mais de 6 dias', '1 a 3 dias', etc.)
- `agrupamento_consultas` — SLA restrição → consulta
- `agrupamento_bacen_consultas` — SLA consulta → BACEN
- `tempo_acionamento` — tempo entre restrição e criação do caso
- `qtde_consultas` — consultas anteriores do seller antes deste caso
- `RECLAMACAO_USUARIO` — texto da mensagem do seller ao BACEN
- `MELHORIA_BACEN` — sugestão de melhoria registrada no caso BACEN

**Classificação de STATUS_BACEN por LIKE:**
- Procedente: `LOWER(STATUS_BACEN) LIKE '%procedente%' AND NOT LIKE '%improcedente%'`
- Improcedente: `LOWER(STATUS_BACEN) LIKE '%improcedente%'`
- Outros analisados: `LOWER(STATUS_BACEN) LIKE 'encerrada%'` (mas não proc/improc)
- Não analisado: todo o resto (valor padrão 'Nao analisado')

---

## Arquivos do projeto

Todos em `C:\Users\nteixeira\Downloads\`:

| Arquivo | Descrição |
|---------|-----------|
| `atualizar_dashboard.ps1` | Script PowerShell principal — recria a tabela BQ, roda todas as queries, gera o HTML e publica no GitHub |
| `dashboard_bacen.html` | HTML gerado localmente (cópia local) |
| `datasuite_bacen.py` | Script Python equivalente para rodar no DataSuite do Meli |
| `dashboard_bacen.log` | Log de cada execução do script PS1 |
| `monitoramento-bacen/` | Repositório git local — contém `index.html` publicado no GitHub Pages |

---

## GitHub Pages

- **Repositório:** https://github.com/nayarateixeira-lab/monitoramento-bacen
- **Branch:** main
- **Arquivo:** index.html
- **URL pública:** https://nayarateixeira-lab.github.io/monitoramento-bacen/

O script faz `git add index.html`, `git commit` e `git push` automaticamente após gerar o HTML.

---

## Agendamento (Windows Task Scheduler)

- **Nome da tarefa:** `Dashboard BACEN - Atualizacao Diaria`
- **Horários:** a cada hora das 08:00 às 20:00 (13 triggers diários)
- **Configuração:** `StartWhenAvailable` — se o PC estiver desligado no horário, roda quando ligar
- **Requisito:** PC precisa estar ligado e com internet

Para rodar manualmente:
```powershell
& "C:\Users\nteixeira\Downloads\atualizar_dashboard.ps1" -OpenBrowser
```

---

## Dashboard HTML — Estrutura

**4 abas:**

### 1. Visão Casos
KPIs: Total de Casos, Abertos, Fechados, Reabilitados (Retirou restrição), Manteve cartão, Outros

Gráficos:
- Dimensão por fechamento (stacked bar mensal)
- Evolução Mensal (line chart)
- Cartão reabilitado por nível (verde/amarelo/vermelho)
- Cartão mantido por nível
- Casos por Equipe (INFRACTION_TYPE — BOF_BIG_SELLERS, SELLER_LONG_TAIL, etc.)
- Casos por Casuística (SUBTYPE_1 — fraude_com_oferta, fco-pre-shipped, etc.)
- Casos por Regra (DETALLE_REGLAS — horizontal bar, todas as regras)

### 2. Visão BACEN
KPIs linha 1: Não analisados (% do total), Procedência (% total e % analisados), 
              Improcedência, Não conclusiva, Cancelada, Não regulada

KPIs linha 2: % Proc/Analisados BACEN, % Improc/Analisados BACEN, 
              Total analisados BACEN, Melhorias BACEN (contagem)

Gráficos:
- Decisão análise BACEN (stacked bar mensal)
- % Decisões por analisados (stacked % mensal)
- Casos por análise BACEN (não analisado vs analisado)
- % Decisões por total de casos
- Casos por Regra (horizontal bar, todas as regras)
- Gráfico de tópicos das mensagens dos sellers (análise por palavras-chave)

Tabelas:
- Mensagem do Seller (com busca e paginação — 200 registros)
- Melhorias BACEN

### 3. Visão SLA
- Donut: casos sem consulta prévia vs com consulta prévia ao acionar BACEN
- Horizontal bar: tempo de acionamento (restrição → caso)
- Stacked bar mensal: consulta prévia por mês
- Acionamento restrição → BACEN (por faixa de dias)
- Acionamento restrição → Consultas
- Acionamento consultas → BACEN

### 4. Comparativo 2025 vs 2026
- Total de casos por mês (side-by-side)
- Casos recebidos pelo BACEN por mês
- Procedências por mês
- Improcedências por mês
- % Procedência/Analisados BACEN por mês
- % Improcedência/Analisados BACEN por mês
- Tabela resumo com variações em % e p.p.

---

## Filtros Globais (afetam todas as abas)

- **Trimestre:** Q1 (Jan-Mar) | Q2 (Abr-Mai) — mutuamente exclusivo com Mês
- **Mês:** Janeiro a Maio
- **Regra:** todas as DETALLE_REGLAS disponíveis
- **Casuística:** top 15 SUBTYPE_1
- **Nível Cartão:** amarelo | vermelho | verde
- **Equipe:** INFRACTION_TYPE top 10
- Botão **↺ Atualizar** — força reload da página do GitHub Pages

---

## Script PS1 — Fluxo de execução

```
1. Recriar tabela materializada (CREATE OR REPLACE TABLE ~2min)
2. Rodar 12 queries de dados no BQ
3. Processar dados em arrays JavaScript
4. Gerar HTML completo (StringBuilder)
5. Salvar HTML local em Downloads/dashboard_bacen.html
6. Copiar para monitoramento-bacen/index.html
7. git add → git commit → git push → GitHub Pages atualiza
```

**RunBQ usa Start-Process** (não pipeline) para evitar problemas de encoding em modo não-interativo (Task Scheduler). Queries são salvas em arquivos .sql temporários sem BOM (UTF-8 sem BOM, pois bq falha com BOM).

**Encoding:** strings não-ASCII nas mensagens dos sellers são convertidas para `\uXXXX` na função `Esc()`. Labels JS hardcoded no HTML usam HTML entities (`&#227;` para ã, etc.).

---

## Script DataSuite (Python 3.13)

Arquivo: `C:\Users\nteixeira\Downloads\datasuite_bacen.py`

Faz exatamente o mesmo que o PS1 mas em Python, para rodar no DataSuite do Meli sem precisar do PC ligado.

**Configuração necessária no DataSuite:**
- **Credentials to include:** `GCP_-_PF_MKT` (ou outra credencial GCP que a Nayara já usa para queries)
  - No código Python é referenciada como `credentials_1`
- **Dependencies:** `google-cloud-bigquery db-dtypes requests`
- **GITHUB_TOKEN:** Personal Access Token clássico do GitHub com escopo `repo`
  - Criado em: github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)
  - Substituir na linha 14 do script: `GITHUB_TOKEN = 'SEU_TOKEN'`

**Diferença do PS1:** o script Python lê o HTML atual do GitHub via API, substitui o bloco de dados JS, e faz push via GitHub REST API (sem precisar do git instalado).

---

## Pontos de atenção / decisões tomadas

1. **Encoding:** maior problema do projeto. PS1 precisa ter BOM UTF-8 para PS5.1 ler corretamente. Arquivos SQL temporários precisam ser SEM BOM para o bq CLI aceitar. Strings de usuário (mensagens) precisam de escape \uXXXX.

2. **Dados 2025:** calculados inline nas queries (não há tabela materializada para 2025), usando o mesmo pipeline de CTEs da tabela 2026 mas com datas '2025-01-01' a '2025-05-31'.

3. **STATUS_BACEN:** usa matching por LIKE, não por valor exato, porque os valores reais são longos: 'Encerrada: reclamação regulada procedente', 'Encerrada: reclamação regulada improcedente', etc.

4. **resolution:** na tabela materializada os valores já estão normalizados: 'Manteve', 'Retirou', 'Outros', 'Sem analise' (sem acento para evitar encoding).

5. **Task Scheduler:** usa Start-Process (não pipeline) para RunBQ porque o modo não-interativo do agendador falha na captura de output via pipeline.

6. **GitHub Pages:** demora ~1 minuto para propagar após o push. O botão "↺ Atualizar" no dashboard faz `location.reload(true)` para forçar busca da versão mais recente.
