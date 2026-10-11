"""
rds_acceso.py — Abre o cierra el acceso temporal al RDS `database-1` desde tu IP y ejecuta SQL (laboratorio).

  python scripts/rds_acceso.py abrir
  python scripts/rds_acceso.py sql "CREATE DATABASE prisma_rag;"
  python scripts/rds_acceso.py sql "CREATE EXTENSION IF NOT EXISTS vector;" --base prisma_rag
  python scripts/rds_acceso.py rol-lector     # crea/actualiza el rol de solo lectura del RAG (clave: rag_lector_password)
  python scripts/rds_acceso.py cerrar

`abrir` pone publicly_accessible=true y una regla del 5432 solo desde tu IP /32. `cerrar` deja todo como estaba
(así Terraform no ve diferencias). La clave se lee de terraform.tfvars y no se imprime.
"""
import argparse
import asyncio
import re
import ssl
import time
import urllib.request
from pathlib import Path

import boto3

REGION = "us-east-1"
INSTANCIA = "database-1"
DESCRIPCION = "temporal: carga RAG"
TFVARS = Path(__file__).resolve().parent.parent / "terraform.tfvars"


def _mi_ip() -> str:
    return urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10).read().decode().strip()


def _variable(nombre: str) -> str:
    m = re.search(rf'(?m)^\s*{nombre}\s*=\s*"(.*)"\s*$', TFVARS.read_text(encoding="utf-8"))
    if not m:
        raise SystemExit(f"No encontré {nombre} en terraform.tfvars")
    return m.group(1)


def _clave() -> str:
    return _variable("db_password")


def _instancia(rds):
    return rds.describe_db_instances(DBInstanceIdentifier=INSTANCIA)["DBInstances"][0]


def _pedir_cambio(rds, publico: bool):
    """Pide el cambio solo si hace falta y la instancia puede recibirlo (si ya está aplicándolo, solo se espera)."""
    inst = _instancia(rds)
    if inst["PubliclyAccessible"] != publico and inst["DBInstanceStatus"] == "available" and not inst.get("PendingModifiedValues"):
        rds.modify_db_instance(DBInstanceIdentifier=INSTANCIA, PubliclyAccessible=publico, ApplyImmediately=True)


def _esperar(rds, publico: bool):
    """Espera hasta que el cambio se aplicó: el waiter solo no basta, porque la instancia sigue `available` un rato."""
    for _ in range(80):
        inst = _instancia(rds)
        if inst["PubliclyAccessible"] == publico and inst["DBInstanceStatus"] == "available" and not inst.get("PendingModifiedValues"):
            return
        _pedir_cambio(rds, publico)
        time.sleep(15)
    raise SystemExit("La instancia no terminó de aplicar el cambio en 20 minutos")


def abrir():
    rds, ec2 = boto3.client("rds", region_name=REGION), boto3.client("ec2", region_name=REGION)
    sg = _instancia(rds)["VpcSecurityGroups"][0]["VpcSecurityGroupId"]
    cidr = f"{_mi_ip()}/32"
    try:
        ec2.authorize_security_group_ingress(GroupId=sg, IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
            "IpRanges": [{"CidrIp": cidr, "Description": DESCRIPCION}],
        }])
    except ec2.exceptions.ClientError as e:
        if "InvalidPermission.Duplicate" not in str(e):
            raise
    _pedir_cambio(rds, True)
    _esperar(rds, True)
    print(f"Abierto para {cidr} (SG {sg}).")


def cerrar():
    rds, ec2 = boto3.client("rds", region_name=REGION), boto3.client("ec2", region_name=REGION)
    sg = _instancia(rds)["VpcSecurityGroups"][0]["VpcSecurityGroupId"]
    reglas = ec2.describe_security_groups(GroupIds=[sg])["SecurityGroups"][0]["IpPermissions"]
    for permiso in reglas:
        propios = [r for r in permiso.get("IpRanges", []) if r.get("Description") == DESCRIPCION]
        if propios and permiso.get("FromPort") == 5432:
            ec2.revoke_security_group_ingress(GroupId=sg, IpPermissions=[{
                "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432, "IpRanges": propios,
            }])
    _pedir_cambio(rds, False)
    _esperar(rds, False)
    print("Cerrado: sin acceso público y sin reglas temporales.")


async def _sql(sentencia: str, base: str):
    import asyncpg

    rds = boto3.client("rds", region_name=REGION)
    inst = _instancia(rds)
    contexto = ssl.create_default_context()
    contexto.check_hostname = False
    contexto.verify_mode = ssl.CERT_NONE
    conn = await asyncpg.connect(
        host=inst["Endpoint"]["Address"], port=5432, user=inst["MasterUsername"], password=_clave(),
        database=base, ssl=contexto, timeout=20,
    )
    try:
        filas = await conn.fetch(sentencia)
        for f in filas:
            print(dict(f))
        print("OK")
    finally:
        await conn.close()


async def _conectar(base: str):
    import asyncpg

    inst = _instancia(boto3.client("rds", region_name=REGION))
    contexto = ssl.create_default_context()
    contexto.check_hostname = False
    contexto.verify_mode = ssl.CERT_NONE
    return await asyncpg.connect(
        host=inst["Endpoint"]["Address"], port=5432, user=inst["MasterUsername"], password=_clave(),
        database=base, ssl=contexto, timeout=20,
    )


async def _rol_lector():
    """Rol de solo lectura del RAG: el workflow lo usa en vez de la clave maestra (ver 11-postgres.tf)."""
    clave = _variable("rag_lector_password")
    if "'" in clave:
        raise SystemExit("rag_lector_password no puede contener comillas simples")
    conn = await _conectar("postgres")
    try:
        existe = await conn.fetchval("SELECT 1 FROM pg_roles WHERE rolname = 'rag_lector'")
        await conn.execute(f"{'ALTER' if existe else 'CREATE'} ROLE rag_lector LOGIN PASSWORD '{clave}'")
        await conn.execute("GRANT CONNECT ON DATABASE prisma_rag TO rag_lector")
    finally:
        await conn.close()
    conn = await _conectar("prisma_rag")
    try:
        await conn.execute("GRANT USAGE ON SCHEMA public TO rag_lector")
        await conn.execute("GRANT SELECT ON documentos, fragmentos TO rag_lector")
    finally:
        await conn.close()
    print("Rol rag_lector listo (solo SELECT sobre documentos y fragmentos).")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("accion", choices=["abrir", "cerrar", "sql", "rol-lector"])
    p.add_argument("sentencia", nargs="?")
    p.add_argument("--base", default="postgres")
    a = p.parse_args()
    if a.accion == "abrir":
        abrir()
    elif a.accion == "cerrar":
        cerrar()
    elif a.accion == "rol-lector":
        asyncio.run(_rol_lector())
    else:
        asyncio.run(_sql(a.sentencia, a.base))


if __name__ == "__main__":
    main()
