"""
Conector OCI para FinOps hubs
=============================
Le os FOCUS cost reports gerados pela Oracle Cloud (bucket da Oracle, namespace "bling",
bucket = OCID da tenancy, pasta "FOCUS Reports/yyyy/mm/dd/"), converte cada CSV.gz em um
parquet tipado e grava no container "ingestion" do FinOps hub seguindo as regras oficiais:

    ingestion/Costs/{yyyy}/{mm}/oci/{tenancy}/{ingestionId}__{arquivo}.parquet
    ingestion/Costs/{yyyy}/{mm}/oci/{tenancy}/manifest.json   (conteudo JSON, nunca vazio)

Regras respeitadas (doc "Ingest from other data sources"):
  * uma pasta por escopo (oci/{tenancy});
  * cada carga substitui TODO o conteudo da pasta (apaga os .parquet antigos antes);
  * todos os arquivos de uma carga compartilham o mesmo ingestionId;
  * shards vazios nao sao enviados (o Data Explorer os rejeita e atrasa a ingestao);
  * manifest.json e o ultimo arquivo gravado e contem pelo menos {}.

Opcionalmente tambem exporta as recomendacoes do OCI Cloud Advisor (servico Optimizer) para
    ingestion/Recommendations/{yyyy}/{mm}/oci/{tenancy}/...
alinhadas ao esquema da tabela Recommendations do hub.

Configuracao (App Settings):
  HUB_STORAGE_ACCOUNT, HUB_INGESTION_CONTAINER (ingestion)
  OCI_TENANCY_OCID, OCI_USER_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_PRIVATE_KEY_PEM (Key Vault reference)
  OCI_MONTHS_BACK (1), OCI_RECOMMENDATIONS_ENABLED (true/false), OCI_SCHEDULE (NCRONTAB, default 0 30 6 * * *)
"""
import gzip
import io
import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func
import oci
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from azure.identity import DefaultAzureCredential
from azure.storage.filedatalake import DataLakeServiceClient

app = func.FunctionApp()

REPORTS_NAMESPACE = "bling"          # namespace fixo dos relatorios de custo da Oracle
FOCUS_PREFIX = "FOCUS Reports/"

# Tipagem do FOCUS (OCI publica FOCUS 1.0 com alguns nomes de 1.0-preview, ex.: UsageQuantity/UsageUnit).
NUMERIC_COLUMNS = {
    "BilledCost", "EffectiveCost", "ListCost", "ContractedCost",
    "ListUnitPrice", "ContractedUnitPrice",
    "PricingQuantity", "UsageQuantity", "ConsumedQuantity",
}
DATETIME_COLUMNS = {"BillingPeriodStart", "BillingPeriodEnd", "ChargePeriodStart", "ChargePeriodEnd"}


# ------------------------------------------------------------------------------ helpers
def _cfg(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise RuntimeError(f"App setting obrigatorio ausente: {name}")
    return value


def _oci_config() -> dict:
    return {
        "user": _cfg("OCI_USER_OCID"),
        "tenancy": _cfg("OCI_TENANCY_OCID"),
        "fingerprint": _cfg("OCI_FINGERPRINT"),
        "region": _cfg("OCI_REGION"),
        "key_content": _cfg("OCI_PRIVATE_KEY_PEM").replace("\\n", "\n"),
    }


def _lake() -> DataLakeServiceClient:
    account = _cfg("HUB_STORAGE_ACCOUNT")
    return DataLakeServiceClient(f"https://{account}.dfs.core.windows.net", credential=DefaultAzureCredential())


def _months(back: int) -> list[tuple[str, str]]:
    """Mes atual e N meses anteriores como (yyyy, mm)."""
    today = datetime.now(timezone.utc).replace(day=1)
    out = []
    y, m = today.year, today.month
    for _ in range(back + 1):
        out.append((f"{y:04d}", f"{m:02d}"))
        m -= 1
        if m == 0:
            m, y = 12, y - 1
    return out


def _tenancy_folder(tenancy_ocid: str) -> str:
    # pasta curta e estavel: ultimos 12 caracteres do OCID
    return tenancy_ocid.split(".")[-1][-12:]


def _replace_folder(fs, folder: str, files: dict[str, bytes], manifest: dict) -> None:
    """Apaga os .parquet antigos, grava os novos e por ultimo o manifest.json."""
    directory = fs.get_directory_client(folder)
    if directory.exists():
        for path in fs.get_paths(path=folder, recursive=False):
            if path.name.lower().endswith(".parquet"):
                fs.get_file_client(path.name).delete_file()
    else:
        directory.create_directory()
    for name, data in files.items():
        directory.get_file_client(name).upload_data(data, overwrite=True)
    body = json.dumps(manifest).encode("utf-8")
    directory.get_file_client("manifest.json").upload_data(body, overwrite=True)


def _to_typed_parquet(csv_gz: bytes) -> tuple[bytes | None, int]:
    """CSV.gz FOCUS da OCI -> parquet tipado. Retorna (bytes, linhas)."""
    with gzip.open(io.BytesIO(csv_gz)) as gz:
        df = pd.read_csv(gz, dtype=str, keep_default_na=False, na_values=[""])
    if df.empty:
        return None, 0
    for col in df.columns:
        if col in NUMERIC_COLUMNS:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("float64")
        elif col in DATETIME_COLUMNS:
            series = df[col]
            if series.dropna().astype(str).str.fullmatch(r"\d{10,13}").all():
                # epoch em milissegundos ou segundos
                numeric = pd.to_numeric(series, errors="coerce")
                unit = "ms" if numeric.dropna().gt(10**11).all() else "s"
                df[col] = pd.to_datetime(numeric, unit=unit, utc=True)
            else:
                df[col] = pd.to_datetime(series, utc=True, errors="coerce")
        # Tags permanece como string JSON (o hub interpreta)
    table = pa.Table.from_pandas(df, preserve_index=False)
    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    return buf.getvalue(), len(df)


# ------------------------------------------------------------------------------ custos
def ingest_focus_costs() -> None:
    cfg = _oci_config()
    oci.config.validate_config(cfg)
    objstore = oci.object_storage.ObjectStorageClient(cfg)
    tenancy = cfg["tenancy"]
    scope_folder = _tenancy_folder(tenancy)
    lake = _lake()
    fs = lake.get_file_system_client(_cfg("HUB_INGESTION_CONTAINER", "ingestion"))
    months_back = int(_cfg("OCI_MONTHS_BACK", "1"))

    for yyyy, mm in _months(months_back):
        prefix = f"{FOCUS_PREFIX}{yyyy}/{mm}/"
        logging.info("OCI FOCUS: listando %s", prefix)
        objects = oci.pagination.list_call_get_all_results(
            objstore.list_objects, REPORTS_NAMESPACE, tenancy, prefix=prefix, fields="name,size,timeCreated"
        ).data.objects
        if not objects:
            logging.info("OCI FOCUS: nenhum arquivo para %s/%s", yyyy, mm)
            continue

        ingestion_id = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        files: dict[str, bytes] = {}
        total_rows = 0
        for obj in objects:
            if obj.size == 0 or not obj.name.lower().endswith(".csv.gz"):
                continue
            raw = objstore.get_object(REPORTS_NAMESPACE, tenancy, obj.name).data.content
            parquet, rows = _to_typed_parquet(raw)
            if not parquet:
                continue
            original = obj.name.replace(FOCUS_PREFIX, "").replace("/", "-").replace(".csv.gz", "")
            files[f"{ingestion_id}__{original}.parquet"] = parquet
            total_rows += rows

        if not files:
            logging.info("OCI FOCUS: todos os arquivos de %s/%s estavam vazios", yyyy, mm)
            continue

        folder = f"Costs/{yyyy}/{mm}/oci/{scope_folder}"
        manifest = {
            "ingestionId": ingestion_id,
            "source": "oci-focus-cost-reports",
            "tenancy": tenancy,
            "billingPeriod": f"{yyyy}-{mm}",
            "files": len(files),
            "rows": total_rows,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }
        _replace_folder(fs, folder, files, manifest)
        logging.info("OCI FOCUS: %s arquivos / %s linhas gravados em %s", len(files), total_rows, folder)


# ------------------------------------------------------------------------------ recomendacoes
def ingest_recommendations() -> None:
    """OCI Cloud Advisor (Optimizer) -> esquema Recommendations do hub."""
    cfg = _oci_config()
    optimizer = oci.optimizer.OptimizerClient(cfg)
    tenancy = cfg["tenancy"]
    scope_folder = _tenancy_folder(tenancy)

    actions = oci.pagination.list_call_get_all_results(
        optimizer.list_resource_actions, compartment_id=tenancy, compartment_id_in_subtree=True, status="PENDING"
    ).data.items
    rows = []
    now = datetime.now(timezone.utc)
    for a in actions:
        saving = float(getattr(a, "estimated_cost_saving", 0.0) or 0.0)
        rows.append({
            "ProviderName": "Oracle",
            "ResourceId": a.resource_id,
            "ResourceName": a.name,
            "ResourceType": a.resource_type,
            "SubAccountId": a.compartment_id,
            "SubAccountName": getattr(a, "compartment_name", None),
            "x_EffectiveCostBefore": None,
            "x_EffectiveCostAfter": None,
            "x_EffectiveCostSavings": saving,
            "x_RecommendationCategory": getattr(getattr(a, "action", None), "type", None),
            "x_RecommendationDate": getattr(a, "time_created", now),
            "x_RecommendationDescription": getattr(getattr(a, "action", None), "description", None),
            "x_RecommendationDetails": json.dumps({
                "recommendationId": a.recommendation_id,
                "categoryId": a.category_id,
                "status": a.status,
                "lifecycleState": a.lifecycle_state,
                "extendedMetadata": getattr(a, "extended_metadata", None),
            }, default=str),
            "x_RecommendationId": a.id,
            "x_ResourceGroupName": None,
            "x_SourceName": "OCI Cloud Advisor",
            "x_SourceProvider": "Oracle",
            "x_SourceType": "CloudAdvisorResourceActions",
            "x_SourceVersion": "optimizer-v1",
            "x_IngestionTime": now,
        })
    if not rows:
        logging.info("OCI Advisor: nenhuma recomendacao pendente")
        return

    df = pd.DataFrame(rows)
    for col in ("x_RecommendationDate", "x_IngestionTime"):
        df[col] = pd.to_datetime(df[col], utc=True, errors="coerce")
    for col in ("x_EffectiveCostBefore", "x_EffectiveCostAfter", "x_EffectiveCostSavings"):
        df[col] = pd.to_numeric(df[col], errors="coerce").astype("float64")
    buf = io.BytesIO()
    pq.write_table(pa.Table.from_pandas(df, preserve_index=False), buf, compression="snappy")

    ingestion_id = now.strftime("%Y%m%d%H%M%S")
    folder = f"Recommendations/{now:%Y}/{now:%m}/oci/{scope_folder}"
    lake = _lake()
    fs = lake.get_file_system_client(_cfg("HUB_INGESTION_CONTAINER", "ingestion"))
    _replace_folder(fs, folder, {f"{ingestion_id}__oci-cloud-advisor.parquet": buf.getvalue()}, {
        "ingestionId": ingestion_id, "source": "oci-cloud-advisor", "rows": len(df), "generatedAt": now.isoformat(),
    })
    logging.info("OCI Advisor: %s recomendacoes gravadas em %s", len(df), folder)


# ------------------------------------------------------------------------------ trigger
@app.timer_trigger(schedule=os.environ.get("OCI_SCHEDULE", "0 30 6 * * *"), arg_name="timer", run_on_startup=False, use_monitor=True)
def oci_focus_ingest(timer: func.TimerRequest) -> None:
    logging.info("Conector OCI iniciado (past_due=%s)", timer.past_due)
    ingest_focus_costs()
    if _cfg("OCI_RECOMMENDATIONS_ENABLED", "true").lower() == "true":
        try:
            ingest_recommendations()
        except Exception as exc:  # recomendacoes nao podem derrubar a carga de custos
            logging.exception("OCI Advisor falhou: %s", exc)
    logging.info("Conector OCI concluido")
