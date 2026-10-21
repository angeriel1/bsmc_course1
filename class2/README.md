# Class 2 — Deploying Our Image: Docker Compose → Helm on Minikube → Persistent Storage

In Class 1 we built a Flask app, containerized it, and had GitHub Actions push it to GHCR.
Tagging the repo `v1.0.0` produced the image:

```
ghcr.io/mbrandeburg/bsmc_course1:1.0.0
```

This class takes that **already-built** image and runs it four ways:

| # | Tool | Storage | Files |
|---|------|---------|-------|
| 1 | Docker Compose | none (stateless) | [docker-compose/docker-compose.yml](docker-compose/docker-compose.yml) |
| 2 | Docker Compose | named volume | [docker-compose/docker-compose.storage.yml](docker-compose/docker-compose.storage.yml) |
| 3 | Helm on minikube | none (stateless) | [helm/hello-app](helm/hello-app) + default `values.yaml` |
| 4 | Helm on minikube | PersistentVolume + PVC | [helm/hello-app](helm/hello-app) + `values-persistence.yaml` |

```
class2/
├── README.md
├── docker-compose/
│   ├── docker-compose.yml           # Part 1: just run the image
│   └── docker-compose.storage.yml   # Part 2: named volume on /app/static
└── helm/
    └── hello-app/
        ├── Chart.yaml
        ├── values.yaml              # Part 3: defaults (no persistence)
        ├── values-persistence.yaml  # Part 4: turns on PV/PVC
        └── templates/
            ├── namespace.yaml
            ├── deployment.yaml
            ├── service.yaml
            ├── pv.yaml              # hostPath PV on the minikube node
            ├── pvc.yaml
            └── NOTES.txt
```

> **Where do the compose files live?** They only reference a published image (no `build:`), so
> they work from inside `class2/docker-compose/` as-is. If you prefer running `docker compose up`
> from the repo root with no `-f`, copy/rename one to `docker-compose.yml` at the root.

---

## 0. Pre-class checklist (instructor)

- [ ] Confirm the tag exists: repo → **Packages** → `bsmc_course1` shows `1.0.0`.
      (`metadata-action` with `type=semver,pattern={{version}}` turns git tag `v1.0.0` into image tag `1.0.0`.)
- [ ] Decide public vs. private package. GHCR packages are **private by default**.
  - Easiest for class: Package settings → *Change visibility* → Public.
  - If it stays private, students need a PAT with `read:packages` (see "Private image" boxes below).
- [ ] Students have installed: Docker Desktop (or Docker Engine + Compose v2), `minikube`, `kubectl`, `helm` (v3).
- [ ] Pre-pull to avoid conference Wi-Fi pain: `docker pull ghcr.io/mbrandeburg/bsmc_course1:1.0.0`
- [ ] `minikube start` once ahead of time (first start downloads a large ISO/image).

Quick sanity check:

```bash
docker --version && docker compose version
minikube version && kubectl version --client && helm version
```

---

## Part 1 — Docker Compose, stateless

**Concept:** `docker run` flags get long. Compose captures them in a file you can commit.

Show the equivalent `docker run` first:

```bash
docker run --rm -p 5001:5001 ghcr.io/mbrandeburg/bsmc_course1:1.0.0
```

Then the Compose version:

```bash
cd class2/docker-compose
docker compose up -d
docker compose ps          # note the (healthy) status from the healthcheck
docker compose logs -f web # Ctrl+C to stop following
```

Visit http://localhost:5001 and http://localhost:5001/cool.

**Talking points** (walk through [docker-compose.yml](docker-compose/docker-compose.yml)):
- `image:` pinned to `1.0.0` — why pinning a semver tag beats `latest` (reproducible, rollback-able).
- `ports: "5001:5001"` — host:container.
- `environment: PORT` — the Dockerfile's `CMD` reads `$PORT`; config via env vars.
- `healthcheck` — image has no `curl`, so we use Python. Compose shows `healthy`/`unhealthy`.
- `restart: unless-stopped` — Compose as a lightweight process supervisor.

**Demo "stateless":**

```bash
docker compose exec web sh -c 'echo "<h1>I was edited!</h1>" > /app/static/helloworld.html'
curl localhost:5001/cool          # shows the edit
docker compose down && docker compose up -d
curl localhost:5001/cool          # edit is GONE — container filesystem is ephemeral
docker compose down
```

> **Private image?** `echo $GHCR_PAT | docker login ghcr.io -u <github-username> --password-stdin`

---

## Part 2 — Docker Compose with persistent storage

**Concept:** Volumes decouple data lifetime from container lifetime.

```bash
docker compose -f docker-compose.storage.yml up -d
docker volume ls | grep class2-storage     # class2-storage_site-content
docker volume inspect class2-storage_site-content
```

**Key teaching moment:** an *empty named volume* mounted over a path that already has files in the
image gets **auto-seeded** by Docker with those files. So the site still works on first boot.
(Kubernetes does *not* do this — we'll hit that in Part 4.)

**Demo persistence:**

```bash
docker compose -f docker-compose.storage.yml exec web \
  sh -c 'echo "<h1>I survive restarts!</h1>" > /app/static/helloworld.html'
curl localhost:5001/cool

docker compose -f docker-compose.storage.yml down      # container removed, volume kept
docker compose -f docker-compose.storage.yml up -d
curl localhost:5001/cool                               # edit is STILL there

docker compose -f docker-compose.storage.yml down -v   # -v also deletes the volume
docker compose -f docker-compose.storage.yml up -d
curl localhost:5001/cool                               # back to the original
docker compose -f docker-compose.storage.yml down -v
```

**Optional: bind mount.** Point out the commented `./my-static:/app/static` line. Contrast:
- **Named volume** — Docker manages where the data lives; seeded from the image.
- **Bind mount** — a real host folder you can open in VS Code; *not* seeded (host folder wins, so
  it must already contain `index.html` and `helloworld.html`). Great for local dev live edits.

---

## Part 3 — Helm on minikube, stateless

**Concept:** Kubernetes runs containers across a cluster; Helm packages the YAML into a
versioned, parameterized "chart" you install/upgrade/rollback as a *release*.

### 3a. Start the cluster

```bash
minikube start
kubectl get nodes
```

> **Private image?** The chart has no pull-secret support, so make the GHCR package public for this part.

### 3b. Tour the chart (before installing)

From `class2/helm`:

- [Chart.yaml](helm/hello-app/Chart.yaml) — chart `version` (the chart) vs. `appVersion` (the app image, `1.0.0`).
- [values.yaml](helm/hello-app/values.yaml) — the knobs. Everything in templates reads from here.
- [templates/deployment.yaml](helm/hello-app/templates/deployment.yaml) — replicas, image, `PORT` env, probes, resources.
- [templates/service.yaml](helm/hello-app/templates/service.yaml) — `LoadBalancer`, exposed locally with `minikube tunnel`.

Render without installing — this is the single best way to demystify Helm:

```bash
helm lint hello-app
helm template demo hello-app | less
```

### 3c. Install

```bash
helm install demo hello-app
helm list
kubectl get deploy,pods,svc -n hello-app
minikube tunnel                    # keep running in a separate terminal
```

Once the Service has an `EXTERNAL-IP`, open `http://<EXTERNAL-IP>` in your browser.
Check it with `kubectl get svc hello-app -n hello-app`.
The chart creates the `hello-app` namespace itself (see `namespace.yaml`); the name comes from `values.yaml`.

### 3d. Show the Helm lifecycle

```bash
# Scale via values, not by editing YAML
helm upgrade demo hello-app --set replicaCount=3
kubectl get pods -n hello-app -w      # Ctrl+C once 3 are Running

helm history demo
helm rollback demo 1                  # back to 1 replica
helm history demo
```

**Self-healing demo:**

```bash
kubectl delete pod -n hello-app -l app=hello-app
kubectl get pods -n hello-app -w      # Deployment immediately creates a replacement
```

**Stateless demo (same as Part 1):**

```bash
POD=$(kubectl get pod -n hello-app -l app=hello-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n hello-app $POD -- sh -c 'echo "<h1>edited in k8s</h1>" > /app/static/helloworld.html'
kubectl delete pod -n hello-app $POD
# once the new pod is Ready, /cool is back to the original
```

Clean up:

```bash
helm uninstall demo
```

---

## Part 4 — Helm on minikube with a PersistentVolume

**Concept:** In Kubernetes, storage is split into two objects:
- **PersistentVolume (PV)** — a piece of actual storage (cluster-wide, admin-ish concern).
- **PersistentVolumeClaim (PVC)** — an app's request for storage (namespaced, dev concern).
- The Pod mounts the **PVC**, never the PV directly.

Tour the new templates:
- [templates/pv.yaml](helm/hello-app/templates/pv.yaml) — a `hostPath` PV at `/data/hello-app` on the
  minikube node (`/data` survives `minikube stop/start`). `Retain` reclaim policy.
- [templates/pvc.yaml](helm/hello-app/templates/pvc.yaml) — claims it by `volumeName` + `storageClassName: manual`.
- [templates/deployment.yaml](helm/hello-app/templates/deployment.yaml) — note three things that only
  appear when `persistence.enabled`:
  1. `volumes:` / `volumeMounts:` wiring the PVC to `/app/static`.
  2. An **initContainer** that copies the image's `/app/static` into the volume *only if it's empty*.
     Callback to Part 2: Docker auto-seeds named volumes; **Kubernetes doesn't**, so without this
     the site would 404.
  3. `strategy: Recreate` — a `ReadWriteOnce` volume shouldn't be shared by old + new pods during a rollout.
- [values-persistence.yaml](helm/hello-app/values-persistence.yaml) — a tiny override file. Layering
  values files (`-f`) is how teams manage dev/stage/prod.

### 4a. Install with persistence

```bash
helm template demo hello-app -f hello-app/values-persistence.yaml | less   # see PV + PVC appear
helm install demo hello-app -f hello-app/values-persistence.yaml

kubectl get pv,pvc -n hello-app     # PVC should be Bound to hello-app-pv
kubectl get pods -n hello-app
POD=$(kubectl get pod -n hello-app -l app=hello-app -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n hello-app $POD -c seed-static   # "Empty volume, seeding from image"
minikube tunnel                    # keep running; open the Service's EXTERNAL-IP
```

### 4b. Prove it persists

```bash
kubectl exec -n hello-app $POD -- sh -c 'echo "<h1>I live on a PersistentVolume</h1>" > /app/static/helloworld.html'
kubectl delete pod -n hello-app $POD
kubectl get pods -n hello-app -w    # wait for new pod

POD=$(kubectl get pod -n hello-app -l app=hello-app -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n hello-app $POD -c seed-static   # "Volume already has content, leaving it alone"
# refresh /cool — the edit survived
```

Peek at the data on the node itself:

```bash
minikube ssh -- ls -la /data/hello-app
minikube ssh -- cat /data/hello-app/helloworld.html
```

### 4c. Data outlives the release (Retain)

```bash
helm uninstall demo
kubectl get pv,pvc -n hello-app     # both gone as Kubernetes objects...
minikube ssh -- cat /data/hello-app/helloworld.html   # ...but the files are still on the node

helm install demo hello-app -f hello-app/values-persistence.yaml
# /cool still shows the edit — new PV pointed at the same hostPath
```

### 4d. (Optional) Dynamic provisioning

Most real clusters don't hand-write PVs; a **StorageClass** provisions them on demand.
minikube ships one called `standard`:

```bash
kubectl get storageclass
# PVC specs are mostly immutable, so reinstall rather than upgrade
helm uninstall demo
helm install demo hello-app -f hello-app/values-persistence.yaml \
  --set persistence.hostPath.enabled=false \
  --set persistence.storageClassName=standard
kubectl get pv,pvc -n hello-app     # PV name is auto-generated (pvc-<uid>), reclaim policy Delete
```

### Reset everything

```bash
helm uninstall demo
minikube ssh -- sudo rm -rf /data/hello-app
# minikube stop   # or: minikube delete
```

---

## Wrap-up / comparison slide

| | Docker Compose | Helm + Kubernetes |
|---|---|---|
| Unit of deploy | service in a YAML file | release of a chart |
| Config | `environment:` / `.env` | `values.yaml`, `--set`, `-f` overlays |
| Scaling | `--scale web=3` (one host) | `replicaCount` across nodes |
| Self-healing | `restart:` policy | Deployment controller + probes |
| Upgrades/rollback | re-`up` with new tag | `helm upgrade` / `helm rollback` with history |
| Persistent data | named volume / bind mount | PV + PVC (+ StorageClass) |
| Volume seeding | automatic for named volumes | you do it (initContainer) |
| Best for | local dev, single host | multi-node, production-style ops |

**Homework ideas**
1. Tag `v1.0.1` with a change to `index.html`, then `helm upgrade demo hello-app --set image.tag=1.0.1`, then roll back.
2. Add a `.env` file and reference it from Compose with `env_file:`.
3. Switch the Service to `ClusterIP` and add an Ingress (`minikube addons enable ingress`).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `ImagePullBackOff` / `ErrImagePull` | Package is private → make it public. Or tag typo (`1.0.0`, not `v1.0.0`). |
| `denied` on `docker pull` | Same — `docker login ghcr.io`. |
| Port 5001 already in use (macOS) | AirPlay Receiver uses 5000/7000; if 5001 is taken change host side: `"5002:5001"`. |
| PVC stuck `Pending` | `storageClassName` on PV and PVC don't match, or leftover PV from a previous install — `kubectl get pv` and delete stale `Released` ones. |
| `/` returns 404 with persistence on | initContainer didn't seed (volume had stray files). `minikube ssh -- sudo rm -rf /data/hello-app/*` and delete the pod. |
| LoadBalancer `EXTERNAL-IP` stays `Pending` | Run `minikube tunnel` in a separate terminal and leave it running. |
