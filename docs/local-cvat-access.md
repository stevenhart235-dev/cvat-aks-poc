# Local CVAT access without Ingress

The CVAT 2.76.0 frontend sets its API origin to the browser origin. The
`cvat-frontend-service` serves only the static UI and does not proxy `/api`. Forwarding
that service directly to port 8081 therefore returns the SPA HTML for API requests and
causes schema and authentication errors.

For this POC, keep the cluster private to `ClusterIP` services and combine the frontend
and backend on one workstation-local origin. The repository proxy has no external
dependencies and binds only to `127.0.0.1`.

Run these commands in three dedicated terminals from the repository root.

Terminal 1 — frontend:

```powershell
kubectl -n cvat port-forward service/cvat-frontend-service 18000:8000 --address 127.0.0.1
```

Terminal 2 — backend:

```powershell
kubectl -n cvat port-forward service/cvat-backend-service 18080:8080 --address 127.0.0.1
```

Terminal 3 — same-origin proxy:

```powershell
node scripts/cvat-local-proxy.mjs
```

Open <http://127.0.0.1:8081/>. The proxy sends `/api`, `/admin`, `/static`,
`/django-rq`, and `/profiler` paths to the backend forward. All other paths go to the
frontend forward. Paths, query strings, methods, bodies, response status/headers, and
HTTP upgrade streams are relayed unchanged.

Before browser testing, these non-authenticated checks should return JSON rather than
the frontend HTML:

```powershell
$health = Invoke-WebRequest http://127.0.0.1:8081/api/server/health/?format=json
$about = Invoke-WebRequest http://127.0.0.1:8081/api/server/about
$schema = Invoke-WebRequest 'http://127.0.0.1:8081/api/schema/?scheme=json'
$health.StatusCode, $health.Headers.'Content-Type'
$about.StatusCode, $about.Headers.'Content-Type'
$schema.StatusCode, $schema.Headers.'Content-Type'
$health.Content | ConvertFrom-Json | Out-Null
$about.Content | ConvertFrom-Json | Out-Null
$schema.Content | ConvertFrom-Json | Out-Null
```

Stop access by pressing Ctrl+C in the proxy and both port-forward terminals. These
processes create no Ingress, public endpoint, or persistent cluster configuration.

Run the offline proxy test with:

```powershell
node --test scripts/tests/test-cvat-local-proxy.mjs
```
