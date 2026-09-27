"""Offline assertions for a Helm --output-dir render; never prints Secret values."""
import base64
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
documents = []
for path in list(root.rglob("*.yaml")) + list(root.rglob("*.yml")):
    documents.extend(document for document in yaml.safe_load_all(path.read_text(encoding="utf-8")) if document)

def cpu_m(value):
    value = str(value)
    return int(value[:-1]) if value.endswith("m") else int(float(value) * 1000)

def memory_mi(value):
    value = str(value)
    for unit, multiplier in (("Ki", 1 / 1024), ("Mi", 1), ("Gi", 1024)):
        if value.endswith(unit):
            return float(value[: -len(unit)]) * multiplier
    return float(value) / (1024 * 1024)

expected_counts = {
    "NetworkPolicy": 1, "PodDisruptionBudget": 1, "ServiceAccount": 5,
    "Secret": 5, "ConfigMap": 9, "PersistentVolumeClaim": 1,
    "ClusterRole": 1, "ClusterRoleBinding": 1, "Role": 1, "RoleBinding": 1,
    "Service": 13, "Deployment": 12, "StatefulSet": 5, "Job": 1, "Pod": 1,
}
counts = {}
for document in documents:
    counts[document["kind"]] = counts.get(document["kind"], 0) + 1
assert counts == expected_counts, counts

cpu = 0
memory = 0
images = []
for document in documents:
    if document["kind"] not in ("Deployment", "StatefulSet"):
        continue
    name = document["metadata"]["name"]
    replicas = document["spec"].get("replicas", 1)
    pod = document["spec"]["template"]["spec"]
    selector = pod.get("nodeSelector", {}).get("workload") == "cvat"
    affinity_map = pod.get("affinity") or {}
    node_affinity = affinity_map.get("nodeAffinity") or {}
    affinity = node_affinity.get("requiredDuringSchedulingIgnoredDuringExecution")
    assert selector or affinity, f"{name} does not require a CVAT node"
    assert any(
        item.get("key") == "workload" and item.get("value") == "cvat" and item.get("effect") == "NoSchedule"
        for item in pod.get("tolerations", [])
    ), f"{name} does not tolerate the CVAT taint"
    for container in pod.get("containers", []):
        images.append(container["image"])
        if name == "cvat-backend-server" and container["name"] == "cvat-nginx":
            assert not container.get("resources"), "released chart unexpectedly gained nginx resources"
            continue
        requests = container.get("resources", {}).get("requests", {})
        assert "cpu" in requests and "memory" in requests, f"missing requests: {name}/{container['name']}"
        cpu += cpu_m(requests["cpu"]) * replicas
        memory += memory_mi(requests["memory"]) * replicas

assert (cpu, int(memory)) == (3050, 5120), (cpu, memory)
assert (cpu + 100, int(memory + 256)) == (3150, 5376)
assert "cvat/server:v2.76.0" in images and "cvat/ui:v2.76.0" in images
assert not any("traefik" in image.lower() or "nuclio" in image.lower() for image in images)
assert not any(document["kind"] == "Ingress" for document in documents)

claims = [document for document in documents if document["kind"] == "PersistentVolumeClaim"]
assert len(claims) == 1 and claims[0]["spec"]["storageClassName"] == "cvat-rwx"
stateful = {document["metadata"]["name"]: document for document in documents if document["kind"] == "StatefulSet"}
for name in ("cvat-postgresql", "cvat-redis-master", "cvat-kvrocks", "cvat-clickhouse-shard0"):
    assert stateful[name]["spec"]["volumeClaimTemplates"][0]["spec"]["storageClassName"] == "cvat-rwo"

secrets = [document for document in documents if document["kind"] == "Secret"]
schema = {
    secret["metadata"]["name"]: sorted(set((secret.get("data") or {}).keys()) | set((secret.get("stringData") or {}).keys()))
    for secret in secrets
}
expected_schema = {
    "cvat-postgres-secret": ["database", "password", "postgres-password", "replication-password", "username"],
    "cvat-redis-secret": ["password"], "cvat-kvrocks-secret": ["password"],
    "cvat-analytics-secret": ["CLICKHOUSE_DB", "CLICKHOUSE_HOST", "CLICKHOUSE_PASSWORD", "CLICKHOUSE_PORT", "CLICKHOUSE_USER"],
    "cvat-grafana": ["admin-password", "admin-user", "ldap-toml"],
}
assert schema == expected_schema, schema
released_defaults = {"cvat_postgresql", "cvat_postgresql_postgres", "cvat_postgresql_replica", "cvat_redis", "cvat_kvrocks", "user"}
sensitive_keys = {
    "cvat-postgres-secret": {"password", "postgres-password", "replication-password"},
    "cvat-redis-secret": {"password"}, "cvat-kvrocks-secret": {"password"},
    "cvat-analytics-secret": {"CLICKHOUSE_PASSWORD"}, "cvat-grafana": {"admin-password"},
}
for secret in secrets:
    secret_name = secret["metadata"]["name"]
    for key, encoded in (secret.get("data") or {}).items():
        if key not in sensitive_keys[secret_name]:
            continue
        try:
            assert base64.b64decode(encoded).decode() not in released_defaults
        except UnicodeDecodeError:
            pass
    for key, value in (secret.get("stringData") or {}).items():
        if key in sensitive_keys[secret_name]:
            assert value not in released_defaults

print("PASS: M4b topology, scheduling, storage, resources, images, exclusions, and secret schema")
print(f"steady requests: {cpu}m CPU / {int(memory)}Mi; initializer peak: {cpu + 100}m / {int(memory + 256)}Mi")
