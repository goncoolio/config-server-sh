# Ubuntu Server Config — HTIC-NETWORKS

Installation and deployment scripts for a multi-tenant Ubuntu 24.04 server
(multiple apps, Caddy HTTPS, PostgreSQL, Adminer).

> 🇫🇷 **French version**: see [README.md](README.md)

## Why this project?

Industrialize the deployment of multiple applications on a **single Ubuntu
VPS**, without Docker/Kubernetes and without depending on a paid third-party
PaaS.

Concretely, this set of scripts solves:

1. **Reproducible server setup** — hardening, swap, Caddy, PostgreSQL in a
   few commands, never to be redone manually
2. **Standardized per-framework deployment** — each app gets its own system
   user, `.env`, systemd service, Caddy block and dedicated deployment script,
   all generated automatically
3. **Zero-downtime updates** — `releases/<timestamp>/` system + `current`
   symlink, one-command rollback
4. **Isolation between apps** — dedicated user per app, 750 permissions,
   systemd sandbox
5. **Pipeline-integrated DB migrations** — the migration command
   (Prisma / Sequelize / TypeORM / Knex / Drizzle / artisan / sqlx) runs
   automatically before each swap; on failure ⇒ swap aborted
6. **User data preservation** — folders like `uploads/` are symlinked from
   `shared/`, never overwritten during an update
7. **Quick diagnostics** — one script displays the full server state (apps,
   ports, Caddy sites, services); an interactive menu handles common ORM ops
   (migrations, seeds, studio)
8. **Modular Caddy** — one file per site (`sites-enabled/*.caddy`),
   add/modify a domain without touching the others
9. **Resilience** — post-deploy health check with automatic rollback if the
   service does not restart, automatic fallback on the entry point if the
   build path varies (`dist/main.js` vs `dist/src/main.js`)
10. **Optimized for small VMs** — automatic swap, explicit Node memory limits,
    no PM2 overhead (direct systemd)

In one sentence: **a minimalist PaaS on a VPS**, opinionated for the
Node/Rust/Laravel/Static stack, designed to host multiple apps on the same
server without unnecessary complexity.

## Execution order (initial install)

```bash
sudo bash 01-initial-setup.sh        # admin user, SSH, UFW, fail2ban, swap
sudo bash 02-install-caddy.sh        # Caddy + PHP-FPM (sites-enabled/ structure)
sudo bash 03-install-database.sh     # menu: PG, MySQL, MariaDB, Mongo, Redis, Supabase
sudo bash 06-adminer-hardening.sh    # Adminer on local port + Caddy protection
```

### Script 03: database menu

Multiple databases can **coexist on the same server**. For each: version
choice, generated root password, bind 127.0.0.1, initial application
databases, daily backups (rotation 7d + 4w), optional web UI.

| # | Database | Versions | Associated web UI |
|---|----------|----------|-------------------|
| 1 | PostgreSQL | 13, 14, 15, 16, 17 | Adminer |
| 2 | MySQL (Oracle) | 8.0, 8.4 LTS | Adminer + phpMyAdmin |
| 3 | MariaDB | 10.6, 10.11, 11.4 LTS | Adminer + phpMyAdmin |
| 4 | MongoDB | 6.0, 7.0, 8.0 | Mongo Express |
| 5 | Redis | 6, 7 | RedisInsight |
| 6 | Supabase (BaaS) | latest stable (Docker) | Studio (built-in) |

All web UIs are exposed via Caddy with basic auth (the script asks for a
domain and a username at the end of each install). All credentials are saved
in `/root/db-credentials/<database>-<date>.txt` (chmod 600).

## View server state

```bash
sudo bash 00-list-apps.sh   # apps, Caddy sites, services, ports
```

This script is also called automatically (in short mode) at the start of
`02b-add-caddy-site.sh` and `05*` to help you avoid name or port collisions
before entering your values.

## Deploy an app (repeat per app)

Choose the script based on the framework:

| Script | Framework | Entry / Server |
|--------|-----------|-----------------------|
| `05a-deploy-node.sh` | NestJS | `dist/main.js` or `dist/src/main.js` via direct systemd (auto-fallback) |
| `05a-deploy-node.sh` | Express | customizable entry (src/server.js, app.js, …) via systemd |
| `05a-deploy-node.sh` | Next.js (SSR) | `next start` via systemd |
| `05b-deploy-rust.sh` | Rust | native binary via systemd |
| `05c-deploy-laravel.sh` | Laravel | PHP-FPM + Caddy `php_fastcgi` |
| `05d-deploy-static.sh` | HTML/CSS, SPA, Next.js export | Caddy `file_server` |

> **No PM2.** All Node services run on direct systemd
> (`Type=simple`, `ExecStart=/usr/bin/node …`). Avoids the dual systemd+PM2
> supervision that caused `spawn EACCES` errors.

### Entry point auto-detection (NestJS / Express)

The NestJS build sometimes produces `dist/main.js`, sometimes
`dist/src/main.js` (depending on your `tsconfig.json` structure). On each
deployment, the script verifies that the configured entry exists; otherwise
it searches for a fallback among:

```
dist/main.js, dist/src/main.js, dist/index.js, dist/app.js,
src/main.js, src/server.js, src/app.js, src/index.js,
server.js, app.js, index.js
```

If a fallback is found, the systemd service `ExecStart` is updated
automatically and `daemon-reload` is called.

### Persistent folders between releases

When installing the `05a/05b/05c` scripts, you can declare folders to
**preserve between deployments** (user uploads, attached files…).

They are stored in `/opt/<app>/shared/<folder>/` and **symlinked** into each
new release. On first run, if the folder exists in the release with content
(e.g. `public/uploads/` from the repo), its content is migrated to `shared/`
automatically.

| Framework | Default-managed folders | Typical additional folders |
|-----------|-----------------------|---------------------|
| Node | none | `uploads`, `public/uploads`, `attachments` |
| Rust | none | `uploads`, `data`, `attachments` |
| Laravel | `storage/`, `bootstrap/cache/` | `public/uploads`, `public/storage` |

### DevDependencies to keep in production (Node)

Some apps use `ts-node` in production (e.g. `prisma db seed` which runs
`ts-node prisma/seed.ts`). The `05a` script asks you for the list of
devDependencies to **reinstall after** `npm prune --omit=dev`.

Example for Prisma + ts-node: `ts-node typescript @types/node`

### Example: NestJS app

```bash
sudo bash 05a-deploy-node.sh
# Framework: 1 (NestJS)
# Name: myapi
# Port: 3002
# Entry point: dist/src/main.js   (or dist/main.js — auto-fallback)
# Caddy domain: api.example.com
```

The script configures:
- dedicated system user `myapi`
- `/opt/myapi/` with `releases/`, `shared/.env`, `current` symlink
- direct systemd service (`Type=simple`, `node $ENTRY`)
- Caddy reverse proxy (if domain provided)
- deployment script `/opt/shared/scripts/deploy-myapi.sh`
- DB Manager `/opt/shared/scripts/myapi-db.sh` (if ORM chosen)

### Approach: build on the server

For **Node (NestJS / Express / Next.js)** and **Laravel** apps, you only send
the **source code** — the server installs dependencies and compiles. Cleaner,
faster to upload, and avoids architecture/version mismatches.

| Framework | What you send | What the server does |
|-----------|-------------------|-----------------------|
| NestJS | source (without `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Express (JS) | source (without `node_modules/`) | `npm ci` → migrations → `npm prune --omit=dev` |
| Express (TS) | source (without `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Next.js SSR | source (without `.next/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Laravel | source (without `vendor/`, `node_modules/`) | `composer install --no-dev` → `artisan migrate --force` → cache |
| Rust | pre-compiled binary (or folder with migrations) | copy + swap (no server build) |

### Example: deploying a version

```bash
# On your dev machine — send raw source
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.next' \
  --exclude '.git' \
  --exclude '.env*' \
  -e 'ssh -p <PORT>' \
  ./ admin@<IP>:/tmp/myapi-src/

# On the server — build + migrations + swap
sudo bash /opt/shared/scripts/deploy-myapi.sh /tmp/myapi-src
```

The deployment script runs in this order:
1. Copy source to `/opt/<app>/releases/<timestamp>/`
2. Symlink `shared/.env` + persistent folders (`uploads/`, etc.)
3. `npm ci --include=dev` (all deps to allow build)
4. Build command (`npm run build`, etc.) if configured
5. **DB migrations** (if configured)
6. `npm prune --omit=dev` (removes devDependencies)
7. Reinstall devDeps marked "to keep" (ts-node, etc.)
8. Verify entry point exists (NestJS auto-fallback)
9. Switch `current` → new release (atomic)
10. `systemctl restart` + **health check** (auto-rollback if KO)
11. Purge old releases (keep last 5)

> If the build, migration **or** service start fails, the previous release
> stays active. The failed release is kept for debugging.

### DB Migrations

Each `05a/05b/05c` script asks for a migration command at install time:

| Stack | Typical command |
|-------|-------------------|
| Prisma | `npx prisma migrate deploy` |
| Sequelize | `npx sequelize-cli db:migrate --env production` |
| TypeORM | `npx typeorm migration:run -d dist/data-source.js` |
| Knex | `npx knex migrate:latest --env production` |
| Drizzle | `npx drizzle-kit migrate` |
| Laravel | `php artisan migrate --force` *(auto, integrated)* |
| sqlx (Rust) | `sqlx migrate run` |

To **change** the migration command of an existing app, rerun the
corresponding `05a/b/c` script — it detects the existing app and regenerates
`deploy-<app>.sh` with the new command.

### DB Manager — interactive menu (Node only)

If you choose an ORM at install (Prisma, Sequelize, TypeORM, Knex, Drizzle),
the `05a` script also generates a dedicated **DB Manager**:

```bash
sudo bash /opt/shared/scripts/<app>-db.sh
```

A numbered menu with **all** available ORM commands (migrations, seeds,
studio, generate, rollback…). Just type a number.

#### Example (Sequelize)

```
════════════════════════════════════════════════
  DB Manager — myapi (sequelize)
════════════════════════════════════════════════

  MIGRATIONS
   1) db:migrate           (run pending migrations)
   2) db:migrate:status    (check status)
   3) db:migrate:undo      (rollback last)
   4) db:migrate:undo:all  (rollback all — DESTRUCTIVE)

  SEEDS
   5) db:seed              (choose: all or one)
   6) db:seed:undo         (rollback last seed)
   7) db:seed:undo:all     (rollback all seeds)

  MODELS
   8) model:generate       (generate new model — interactive)

   c) Custom npm script
   r) Reload app (systemctl reload)
   l) Show recent logs
   q) Quit

Your choice: 5
```

When you choose the **seed** option (e.g. option 5 for Sequelize), a submenu
lists all files from `seeders/`:

```
Choose a file:
   0) ⭐ All (sequential execution)
   1) 20260101000000-create-users.js
   2) 20260101000001-create-roles.js
   3) 20260101000002-permissions.js

  Choice: 2
```

You can run **all** seeds (0) or **just one** (number).

| Common to all ORMs | Description |
|------------------------|-------------|
| `c` | Run an `npm run <X>` script from `package.json` |
| `r` | `systemctl reload <app>` |
| `l` | Recent logs `journalctl -u <app>` |
| `q` | Quit |

Destructive operations (rollback all, drop, etc.) require an explicit
confirmation (type `CONFIRMER`).

### Rollback

```bash
# List releases
ls -lt /opt/<app>/releases/

# Rollback to a previous version
sudo ln -sfn /opt/<app>/releases/20260101_143022 /opt/<app>/current
sudo systemctl restart <app>
```

## Caddy — site management

The Caddy config is modular:

```
/etc/caddy/
├── Caddyfile                    # main config (imports sites-enabled/)
├── snippets/
│   ├── security-headers.caddy   # shared security headers
│   └── logging.caddy            # JSON logging
└── sites-enabled/
    ├── api.example.com.caddy
    ├── app.example.com.caddy
    └── dbadmin.example.com.caddy
```

### Add a site without redeploying the app

```bash
sudo bash 02b-add-caddy-site.sh
# or directly:
sudo bash 02b-add-caddy-site.sh api.example.com
```

Site types: `api` (reverse proxy), `spa`, `static`, `laravel`, `nextjs`.

### Modify/delete a site

```bash
# Modify
sudo nano /etc/caddy/sites-enabled/api.example.com.caddy
sudo systemctl reload caddy

# Or rerun the script (overwrites)
sudo bash 02b-add-caddy-site.sh api.example.com

# Delete
sudo rm /etc/caddy/sites-enabled/api.example.com.caddy
sudo systemctl reload caddy
```

## Which script for what?

Two types of updates — don't confuse them:

| Need | Script to use | Effect |
|--------|-------------------|-------|
| **New code / binary** (new app version) | `sudo bash /opt/shared/scripts/deploy-<app>.sh <source>` | Creates `releases/<timestamp>/`, switches `current`, reloads service (zero-downtime) |
| **Change port, env vars, entry point, Caddy domain** | `sudo bash 05a/b/c/d-deploy-*.sh` | Detects existing app, regenerates `.env` / systemd / Caddy block — **does not touch deployed code** |
| **Add or modify a Caddy domain** (without touching the app) | `sudo bash 02b-add-caddy-site.sh [domain]` | Only writes `sites-enabled/<domain>.caddy`, reloads Caddy |
| **Rollback to a previous release** | `sudo ln -sfn /opt/<app>/releases/<old> /opt/<app>/current && sudo systemctl restart <app>` | Atomic symlink switch |
| **View server state** (apps, ports, sites) | `sudo bash 00-list-apps.sh` | Full overview |
| **Initial install of a new app** | `sudo bash 05a/b/c/d-deploy-*.sh` (if name does not yet exist in `/opt/`) | Creates everything from scratch |

### `05*` scripts idempotence

All `05a/b/c/d` scripts are **idempotent**. If the app already exists they
display `[WARN] App <name> already exists → CONFIG UPDATE mode` and update
only:
- the `.env` file (in `shared/`)
- the systemd config
- the Caddy block (if domain provided)

Existing releases and the `current` symlink are not touched — only the next
`deploy-<app>.sh` will create a new release with new code.

## Structure of a deployed app

```
/opt/<app>/
├── releases/
│   ├── 20260101_143022/        # release N-2
│   ├── 20260101_150811/        # release N-1
│   └── 20260101_161533/        # current release
├── shared/
│   ├── .env                    # persists between releases
│   ├── uploads/                # user folders (symlinked)
│   └── storage/                # Laravel
├── logs/
│   └── systemd.log
└── current → releases/20260101_161533
```

## Troubleshooting

```bash
# Per-app logs
systemctl status <app>
journalctl -u <app> -f
tail -f /opt/<app>/logs/systemd-err.log

# Per-site Caddy logs
tail -f /var/log/caddy/<domain_with_underscores>.log

# Validate Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# List releases
ls -lt /opt/<app>/releases/
```
