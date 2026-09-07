"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Teste de IMPORTACAO do main.py: reproduz o que o uvicorn faz em producao ("import main") e falha se o
modulo nao carregar. Existe porque um NameError na importacao (funcao usada antes de ser definida) passou
pelos testes de logica e pela previa, e so apareceu no Container Apps como ContainerBackOff.

Roda em QUALQUER maquina, mesmo sem as bibliotecas da aplicacao instaladas: toda biblioteca de terceiros
ausente (fastapi, matplotlib, reportlab, openpyxl, azure-*, pyarrow...) e substituida por um modulo curinga
que aceita qualquer atributo, chamada ou subimportacao. O que se testa e o CODIGO DO KIT: ordem de definicao,
nomes, rotas, configuracao inicial. Dependencias faltando nao sao erro do codigo (a imagem as instala pelo
requirements.txt), entao nunca bloqueiam.

Excecao: pandas e numpy precisam ser reais, porque o codigo executa logica com eles ao importar. Sem eles o
teste e PULADO (codigo de saida 2), com aviso, e o instalador segue.

Codigos de saida: 0 = passou; 1 = erro no codigo do kit; 2 = teste pulado (ambiente sem pandas/numpy).

Uso:  python api/test_import.py
"""
from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import types

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

# Ambiente equivalente ao de producao com storage, sem rede: a fonte e criada mas nao le nada agora.
os.environ.setdefault("DATA_BACKEND", "storage")
os.environ.setdefault("HUB_STORAGE_ACCOUNT", "teste-import")
os.environ["ALERTS_SCHEDULER"] = "false"
os.environ["ALERTS_ON_LOAD"] = "false"
os.environ["STATE_DIR"] = tempfile.mkdtemp(prefix="finops-import-")
os.environ.pop("STATE_STORAGE_ACCOUNT", None)

ROTAS: list[tuple[str, str]] = []
SUBSTITUIDOS: set[str] = set()

# Bibliotecas de terceiros que o codigo importa. Tudo que estiver ausente vira curinga.
TERCEIROS = ("fastapi", "matplotlib", "reportlab", "openpyxl", "azure", "pyarrow", "uvicorn", "starlette",
             "pydantic", "anyio", "httpx", "requests")
ESSENCIAIS = ("pandas", "numpy")


class _Chamavel:
    """Objeto que pode ser chamado, indexado, usado como decorador, classe base ou gerenciador de contexto."""

    def __init__(self, nome="curinga"):
        self._nome = nome

    def __call__(self, *a, **_kw):
        # Usado como decorador: devolve a funcao original para ela continuar existindo no modulo.
        if len(a) == 1 and callable(a[0]) and not isinstance(a[0], _Chamavel):
            return a[0]
        return _Chamavel(self._nome + "()")

    def __getattr__(self, item):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(item)
        return _Chamavel(f"{self._nome}.{item}")

    def __getitem__(self, _k): return _Chamavel(self._nome + "[]")
    def __iter__(self): return iter(())
    def __enter__(self): return self
    def __exit__(self, *_a): return False
    def __bool__(self): return True
    def __mro_entries__(self, _bases): return (object,)   # permite "class X(curinga.Qualquer): ..."
    def __repr__(self): return f"<curinga {self._nome}>"
    def __str__(self): return self._nome
    def __hash__(self): return hash(self._nome)


class _Curinga(types.ModuleType):
    """Modulo que aceita qualquer coisa: atributo vira _Chamavel; e um pacote, entao subimportacoes resolvem."""

    def __init__(self, nome):
        super().__init__(nome)
        self.__path__ = []
        self.__version__ = "0.0.0"
        self.__file__ = f"<curinga {nome}>"

    def __getattr__(self, item):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(item)
        valor = _Chamavel(f"{self.__name__}.{item}")
        setattr(self, item, valor)
        return valor


class _AppFalso:
    """Substituto do FastAPI() que registra as rotas declaradas pelo main.py."""

    def __init__(self, **_kw):
        self.rotas = ROTAS

    def _reg(self, metodo):
        def decorador(caminho, **_kw):
            def envolve(fn):
                ROTAS.append((metodo, caminho))
                return fn
            return envolve
        return decorador

    def get(self, caminho, **kw): return self._reg("GET")(caminho, **kw)
    def post(self, caminho, **kw): return self._reg("POST")(caminho, **kw)
    def patch(self, caminho, **kw): return self._reg("PATCH")(caminho, **kw)
    def put(self, caminho, **kw): return self._reg("PUT")(caminho, **kw)
    def delete(self, caminho, **kw): return self._reg("DELETE")(caminho, **kw)
    def add_middleware(self, *_a, **_kw): pass
    def mount(self, *_a, **_kw): pass
    def on_event(self, *_a, **_kw): return lambda fn: fn


class _HTTPException(Exception):
    def __init__(self, status_code=500, detail="", **_kw):
        super().__init__(detail)
        self.status_code, self.detail = status_code, detail


class _Localizador(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    """Para cada biblioteca de terceiros AUSENTE, entrega um curinga (inclusive submodulos)."""

    def __init__(self, ausentes):
        self.ausentes = ausentes

    def find_spec(self, nome, path=None, target=None):
        if nome.split(".")[0] in self.ausentes:
            return importlib.machinery.ModuleSpec(nome, self, is_package=True)
        return None

    def create_module(self, spec):
        m = _Curinga(spec.name)
        if spec.name == "fastapi":
            m.FastAPI = _AppFalso
            m.HTTPException = _HTTPException
            m.Request = object
        SUBSTITUIDOS.add(spec.name.split(".")[0])
        return m

    def exec_module(self, module):
        pass


def _preparar_ambiente() -> list[str]:
    faltam_essenciais = [n for n in ESSENCIAIS if importlib.util.find_spec(n) is None]
    if faltam_essenciais:
        return faltam_essenciais
    ausentes = {n for n in TERCEIROS if importlib.util.find_spec(n) is None}
    if ausentes:
        sys.meta_path.insert(0, _Localizador(ausentes))
    return []


def main() -> int:
    faltam = _preparar_ambiente()
    if faltam:
        print(f"  !  Teste de importacao PULADO: esta maquina nao tem {', '.join(faltam)}.")
        print("     Nao e erro do codigo. O container instala tudo pelo requirements.txt.")
        return 2

    try:
        main_mod = importlib.import_module("main")
    except Exception as exc:  # noqa: BLE001
        print(f"  X  'import main' FALHOU: {type(exc).__name__}: {exc}")
        print("     E exatamente isto que derruba o container na inicializacao (ContainerBackOff).")
        import traceback
        for fr in traceback.extract_tb(exc.__traceback__):
            if AQUI in (fr.filename or ""):
                print(f"     -> {os.path.basename(fr.filename)}, linha {fr.lineno}: {fr.line}")
        return 1

    if SUBSTITUIDOS:
        print(f"  (bibliotecas ausentes nesta maquina, substituidas por curingas: {', '.join(sorted(SUBSTITUIDOS))})")
    print("  OK 'import main' carregou o modulo de cima a baixo")

    falhas = 0

    def ok(cond, msg):
        nonlocal falhas
        print(f"  {'OK' if cond else 'X '} {msg}")
        if not cond:
            falhas += 1

    fonte = getattr(main_mod, "_fonte", None)
    ok(fonte is not None, "fonte de dados configurada na importacao (configurar_fonte_padrao)")
    ok(getattr(main_mod, "_erro_config", None) in (None, ""), f"sem erro de configuracao (erro={getattr(main_mod, '_erro_config', None)!r})")
    ok(callable(getattr(main_mod, "_pos_carga", None)), "_pos_carga definida")
    ok(fonte is not None and main_mod._pos_carga in getattr(fonte, "ouvintes_pos_carga", []), "ouvinte pos-carga registrado na fonte")
    ok(callable(getattr(main_mod, "configurar_fonte", None)), "configurar_fonte disponivel para a previa e os testes")
    ok(callable(getattr(main_mod, "iniciar_agendador", None)), "iniciar_agendador disponivel")

    if "fastapi" in SUBSTITUIDOS:
        caminhos = {c for _m, c in ROTAS}
        esperadas = ["/api/health", "/api/status", "/api/sobre", "/api/visao-geral", "/api/nuvens", "/api/governanca",
                     "/api/ia", "/api/bancos", "/api/chargeback", "/api/otimizacao", "/api/previsao", "/api/alertas",
                     "/api/export/pdf", "/api/export/excel", "/api/relatorio", "/api/centros-custo", "/api/regras-alerta",
                     "/api/orcamentos", "/api/alertas/avaliar", "/api/configuracoes/tags-obrigatorias"]
        for c in esperadas:
            ok(c in caminhos, f"rota registrada: {c}")
        print(f"  {len(ROTAS)} rotas registradas no total")
    else:
        rotas_reais = [r.path for r in getattr(main_mod.app, "routes", []) if hasattr(r, "path")]
        ok("/api/health" in rotas_reais and "/api/status" in rotas_reais, f"rotas registradas no FastAPI real ({len(rotas_reais)})")

    ok(getattr(fonte, "_cache", None) is None, "fonte criada sem carregar dado (carga preguicosa)")

    print()
    print("Todos os testes de importacao passaram." if falhas == 0 else f"{falhas} falha(s) no codigo do kit.")
    return 0 if falhas == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
