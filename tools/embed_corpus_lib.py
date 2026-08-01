"""Shared Chroma + OpenAI plumbing for the corpus scripts.

Importable module name (underscores) because `embed-corpus.py` cannot be
imported. Standard library only: the chromadb and openai packages would both
work and neither earns a dependency for a handful of HTTP calls.
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS = ROOT / "content/corpus.jsonl"
ENV_FILE = ROOT / "supabase/functions/.env"

CHROMA_URL = os.environ.get("CHROMA_URL", "http://localhost:8000").rstrip("/")
CHROMA_TENANT = os.environ.get("CHROMA_TENANT", "default_tenant")
CHROMA_DATABASE = os.environ.get("CHROMA_DATABASE", "default_database")
COLLECTION = os.environ.get("CAL_COLLECTION", "cal_content")
EMBED_MODEL = os.environ.get("CAL_EMBED_MODEL", "text-embedding-3-small")


def load_env():
    """Read KEY=VALUE pairs from the function's .env. Never prints a value."""
    if not ENV_FILE.exists():
        return {}
    values = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def resolve_key():
    key = os.environ.get("OPENAI_API_KEY") or load_env().get("OPENAI_API_KEY")
    if not key or key == "sk-replace-me":
        sys.exit(
            "FAIL: no usable OPENAI_API_KEY.\n"
            "      Set it in supabase/functions/.env (see .env.example) or export it."
        )
    return key


def post(url, payload, headers=None):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers=dict({"Content-Type": "application/json"}, **(headers or {})),
        method="POST",
    )
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        sys.exit("FAIL: %s -> %s\n%s" % (url, error.code, error.read().decode()[:600]))
    except urllib.error.URLError as error:
        sys.exit("FAIL: could not reach %s (%s)\nIs Chroma running?" % (url, error.reason))


def get(url):
    try:
        with urllib.request.urlopen(url) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        sys.exit("FAIL: %s -> %s\n%s" % (url, error.code, error.read().decode()[:600]))
    except urllib.error.URLError as error:
        sys.exit("FAIL: could not reach %s (%s)\nIs Chroma running?" % (url, error.reason))


def collections_url():
    return "%s/api/v2/tenants/%s/databases/%s/collections" % (
        CHROMA_URL, CHROMA_TENANT, CHROMA_DATABASE
    )


def ensure_collection():
    """Cosine, explicitly.

    Chroma defaults to l2. For unit-length embeddings the two rank identically,
    so this changes no result — but it makes the distances in a response mean
    what a reader assumes (0 = identical, 1 = orthogonal), which is worth a field.
    """
    created = post(
        collections_url(),
        {"name": COLLECTION, "get_or_create": True, "configuration": {"hnsw": {"space": "cosine"}}},
    )
    return created["id"]


def embed(texts, api_key):
    response = post(
        "https://api.openai.com/v1/embeddings",
        {"model": EMBED_MODEL, "input": texts},
        headers={"Authorization": "Bearer %s" % api_key},
    )
    # The API preserves input order, but the objects carry an explicit index and
    # mismatching a vector to its text would be silent and awful to debug.
    return [item["embedding"] for item in sorted(response["data"], key=lambda i: i["index"])]


def chroma_query(collection_id, vector, kinds, n_results):
    """Nearest chunks, restricted to `kinds`. Mirrors the Edge Function's query."""
    where = {"kind": {"$eq": kinds[0]}} if len(kinds) == 1 else {"$or": [{"kind": {"$eq": k}} for k in kinds]}
    result = post(
        "%s/%s/query" % (collections_url(), collection_id),
        {
            "query_embeddings": [vector],
            "n_results": n_results,
            "where": where,
            "include": ["documents", "metadatas", "distances"],
        },
    )
    return [
        {"id": chunk_id, "document": document, "metadata": metadata, "distance": distance}
        for chunk_id, document, metadata, distance in zip(
            result["ids"][0],
            result["documents"][0],
            result["metadatas"][0],
            result["distances"][0],
        )
    ]


def delete(url):
    """DELETE, tolerating a 404 — dropping something absent is success."""
    request = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(request) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return ""
        sys.exit("FAIL: %s -> %s\n%s" % (url, error.code, error.read().decode()[:400]))
    except urllib.error.URLError as error:
        sys.exit("FAIL: could not reach %s (%s)\nIs Chroma running?" % (url, error.reason))
