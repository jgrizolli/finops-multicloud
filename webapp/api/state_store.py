"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Persistencia do que a interface precisa lembrar: centros de custo, orcamentos, regras de
alerta, alertas gerados e configuracoes.

Dois backends com a mesma interface:
  LocalJsonStore   um arquivo JSON por colecao. Usado no -RunLocal, na previa e nos testes.
                   No App Service, a pasta /home persiste entre reinicios, entao tambem
                   funciona em producao para uma unica instancia.
  AzureTableStore  Azure Table Storage com identidade gerenciada. Recomendado em producao:
                   sobrevive a redeploy, aceita mais de uma instancia e nao usa segredo.

A escolha e automatica: se STATE_STORAGE_ACCOUNT estiver definido, usa Table Storage.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone

log = logging.getLogger("finops.state")

COLECOES = ("centros_custo", "orcamentos", "regras_alerta", "alertas", "configuracoes")


def agora_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def novo_id() -> str:
    return uuid.uuid4().hex[:12]


class StateStore(ABC):
    @abstractmethod
    def listar(self, colecao: str) -> list[dict]: ...

    @abstractmethod
    def obter(self, colecao: str, id_: str) -> dict | None: ...

    @abstractmethod
    def salvar(self, colecao: str, item: dict) -> dict: ...

    @abstractmethod
    def remover(self, colecao: str, id_: str) -> bool: ...

    @abstractmethod
    def descricao(self) -> str: ...

    def salvar_varios(self, colecao: str, itens: list[dict]) -> list[dict]:
        return [self.salvar(colecao, i) for i in itens]

    def limpar(self, colecao: str) -> int:
        n = 0
        for item in self.listar(colecao):
            if self.remover(colecao, item["id"]):
                n += 1
        return n


def _preparar(item: dict) -> dict:
    item = dict(item)
    item.setdefault("id", novo_id())
    item.setdefault("criadoEm", agora_iso())
    item["atualizadoEm"] = agora_iso()
    return item


class LocalJsonStore(StateStore):
    def __init__(self, pasta: str):
        self.pasta = pasta
        os.makedirs(pasta, exist_ok=True)
        self._trava = threading.RLock()

    def _caminho(self, colecao):
        return os.path.join(self.pasta, f"{colecao}.json")

    def _ler(self, colecao) -> dict:
        c = self._caminho(colecao)
        if not os.path.exists(c):
            return {}
        try:
            with open(c, encoding="utf-8") as f:
                dados = json.load(f)
            return dados if isinstance(dados, dict) else {}
        except Exception:  # noqa: BLE001
            log.exception("Arquivo de estado corrompido: %s", c)
            return {}

    def _gravar(self, colecao, dados: dict) -> None:
        tmp = self._caminho(colecao) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(dados, f, ensure_ascii=False, indent=1, default=str)
        os.replace(tmp, self._caminho(colecao))

    def listar(self, colecao):
        with self._trava:
            return sorted(self._ler(colecao).values(), key=lambda i: i.get("criadoEm", ""))

    def obter(self, colecao, id_):
        with self._trava:
            return self._ler(colecao).get(id_)

    def salvar(self, colecao, item):
        with self._trava:
            dados = self._ler(colecao)
            item = _preparar(item)
            if item["id"] in dados:
                item["criadoEm"] = dados[item["id"]].get("criadoEm", item["criadoEm"])
            dados[item["id"]] = item
            self._gravar(colecao, dados)
            return item

    def remover(self, colecao, id_):
        with self._trava:
            dados = self._ler(colecao)
            if id_ not in dados:
                return False
            del dados[id_]
            self._gravar(colecao, dados)
            return True

    def descricao(self):
        return f"arquivos JSON em {self.pasta}"


class AzureTableStore(StateStore):
    """Uma tabela por colecao. Cada item vira uma entidade com o JSON inteiro em uma coluna."""

    PARTICAO = "finops"

    def __init__(self, conta: str):
        from azure.data.tables import TableServiceClient
        from azure.identity import DefaultAzureCredential

        self.conta = conta
        self._svc = TableServiceClient(endpoint=f"https://{conta}.table.core.windows.net",
                                       credential=DefaultAzureCredential(exclude_interactive_browser_credential=True))
        self._tabelas: dict = {}
        self._trava = threading.Lock()

    def _tabela(self, colecao):
        nome = "finops" + colecao.replace("_", "")
        with self._trava:
            if nome not in self._tabelas:
                self._tabelas[nome] = self._svc.create_table_if_not_exists(nome)
        return self._tabelas[nome]

    @staticmethod
    def _para_item(entidade) -> dict:
        try:
            return json.loads(entidade.get("json", "{}"))
        except Exception:  # noqa: BLE001
            return {}

    def listar(self, colecao):
        t = self._tabela(colecao)
        itens = [self._para_item(e) for e in t.query_entities(f"PartitionKey eq '{self.PARTICAO}'")]
        return sorted((i for i in itens if i), key=lambda i: i.get("criadoEm", ""))

    def obter(self, colecao, id_):
        from azure.core.exceptions import ResourceNotFoundError

        try:
            return self._para_item(self._tabela(colecao).get_entity(self.PARTICAO, id_))
        except ResourceNotFoundError:
            return None

    def salvar(self, colecao, item):
        from azure.data.tables import UpdateMode

        item = _preparar(item)
        existente = self.obter(colecao, item["id"])
        if existente:
            item["criadoEm"] = existente.get("criadoEm", item["criadoEm"])
        self._tabela(colecao).upsert_entity(
            {"PartitionKey": self.PARTICAO, "RowKey": item["id"], "json": json.dumps(item, ensure_ascii=False, default=str)},
            mode=UpdateMode.REPLACE)
        return item

    def remover(self, colecao, id_):
        from azure.core.exceptions import ResourceNotFoundError

        try:
            self._tabela(colecao).delete_entity(self.PARTICAO, id_)
            return True
        except ResourceNotFoundError:
            return False

    def descricao(self):
        return f"Azure Table Storage em {self.conta}"


def criar_store() -> StateStore:
    conta = os.getenv("STATE_STORAGE_ACCOUNT", "").strip()
    if conta:
        try:
            store = AzureTableStore(conta)
            log.info("Estado: %s", store.descricao())
            return store
        except Exception:  # noqa: BLE001
            log.exception("Nao consegui usar o Table Storage %s, caindo para arquivos locais", conta)

    pasta = os.getenv("STATE_DIR", "").strip()
    if not pasta:
        # No App Service Linux, /home persiste entre reinicios e publicacoes.
        pasta = "/home/finops-state" if os.path.isdir("/home") and os.access("/home", os.W_OK) else os.path.join(os.getcwd(), "state")
    store = LocalJsonStore(pasta)
    log.info("Estado: %s", store.descricao())
    return store
