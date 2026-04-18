# Config serveur Ubuntu — HTIC-NETWORKS

Scripts d'installation et de déploiement multi-apps sur un VPS Ubuntu 24.04.
*Installation and deployment scripts for a multi-tenant Ubuntu 24.04 server.*

<p align="center">
  <a href="#-english"><b>🇬🇧 English</b></a> &nbsp;·&nbsp;
  <a href="#-français"><b>🇫🇷 Français</b></a> &nbsp;·&nbsp;
  <a href="#-changelog"><b>📝 Changelog</b></a>
</p>

---

<details open>
<summary><h2 id="-english">🇬🇧 English</h2></summary>

### Why this project?

Industrialize the deployment of multiple applications on a **single Ubuntu
VPS**, without Docker/Kubernetes and without depending on a paid third-party
PaaS.

Concretely, this set of scripts solves:

1. **Reproducible server setup** — hardening, swap, Caddy, databases in a
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
8. **Modular Caddy** — one file per site (`sites-enabled/*.caddy`)
9. **Resilience** — post-deploy health check with automatic rollback if the
   service does not restart, automatic fallback on the entry point if the
   build path varies (`dist/main.js` vs `dist/src/main.js`)
10. **Optimized for small VMs** — automatic swap, explicit Node memory limits,
    no PM2 overhead (direct systemd)

In one sentence: **a minimalist PaaS on a VPS**, opinionated for the
Node/Rust/Laravel/Static stack, designed to host multiple apps on the same
server without unnecessary complexity.

### Initial install order

```bash
sudo bash 01-initial-setup.sh        # admin user, SSH, UFW, fail2ban, swap
sudo bash 02-install-caddy.sh        # Caddy + PHP-FPM (sites-enabled/ structure)
sudo bash 03-install-database.sh     # menu: PG, MySQL, MariaDB, Mongo, Redis, Supabase
sudo bash 06-adminer-hardening.sh    # Adminer on local port + Caddy protection
```

#### Script 03: database menu

Multiple databases can **coexist on the same server**. For each: version
choice, generated root password, bind 127.0.0.1, initial application
databases, daily backups (rotation 7d + 4w), optional web UI.

| # | Database | Versions | Web UI |
|---|----------|----------|--------|
| 1 | PostgreSQL | 13, 14, 15, 16, 17 | Adminer |
| 2 | MySQL (Oracle) | 8.0, 8.4 LTS | Adminer + phpMyAdmin |
| 3 | MariaDB | 10.6, 10.11, 11.4 LTS | Adminer + phpMyAdmin |
| 4 | MongoDB | 6.0, 7.0, 8.0 | Mongo Express |
| 5 | Redis | 6, 7 | RedisInsight |
| 6 | Supabase (BaaS) | latest stable (Docker) | Studio (built-in) |

All web UIs are exposed via Caddy with basic auth (the script asks for a
domain and a username at the end of each install). All credentials are saved
in `/root/db-credentials/<database>-<date>.txt` (chmod 600).

### View server state

```bash
sudo bash 00-list-apps.sh   # apps, Caddy sites, services, ports
```

This script is also called automatically (in short mode) at the start of
`02b-add-caddy-site.sh` and `05*` to help you avoid name or port collisions
before entering your values.

### Deploy an app (repeat per app)

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

#### Entry point auto-detection (NestJS / Express)

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

#### Persistent folders between releases

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

#### DevDependencies to keep in production (Node)

Some apps use `ts-node` in production (e.g. `prisma db seed` which runs
`ts-node prisma/seed.ts`). The `05a` script asks you for the list of
devDependencies to **reinstall after** `npm prune --omit=dev`.

Example for Prisma + ts-node: `ts-node typescript @types/node`

#### Build-on-server approach

For **Node** and **Laravel** apps, you only send the **source code** — the
server installs dependencies and compiles. Cleaner, faster to upload, avoids
architecture/version mismatches.

| Framework | What you send | What the server does |
|-----------|-------------------|-----------------------|
| NestJS | source (no `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Express (JS) | source (no `node_modules/`) | `npm ci` → migrations → `npm prune --omit=dev` |
| Express (TS) | source (no `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Next.js SSR | source (no `.next/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Laravel | source (no `vendor/`, `node_modules/`) | `composer install --no-dev` → `artisan migrate --force` → cache |
| Rust | pre-compiled binary (or folder with migrations) | copy + swap (no server build) |

#### Deployment example

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

#### DB Migrations

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

#### DB Manager — interactive menu (Node only)

If you choose an ORM at install (Prisma, Sequelize, TypeORM, Knex, Drizzle),
the `05a` script also generates a dedicated **DB Manager**:

```bash
sudo bash /opt/shared/scripts/<app>-db.sh
```

A numbered menu with **all** available ORM commands (migrations, seeds,
studio, generate, rollback…). Just type a number.

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

When you choose a **seed** option, a submenu lists all files from `seeders/`:

```
Choose a file:
   0) ⭐ All (sequential execution)
   1) 20260101000000-create-users.js
   2) 20260101000001-create-roles.js
   3) 20260101000002-permissions.js

  Choice: 2
```

You can run **all** seeds (0) or **just one** (number). Destructive operations
require an explicit `CONFIRMER` prompt.

### Caddy — site management

Modular config:

```
/etc/caddy/
├── Caddyfile                    # main (imports sites-enabled/)
├── snippets/
│   ├── security-headers.caddy
│   └── logging.caddy
└── sites-enabled/
    ├── api.example.com.caddy
    ├── app.example.com.caddy
    └── dbadmin.example.com.caddy
```

```bash
# Add a site without redeploying the app
sudo bash 02b-add-caddy-site.sh api.example.com

# Modify
sudo nano /etc/caddy/sites-enabled/api.example.com.caddy
sudo systemctl reload caddy

# Delete
sudo rm /etc/caddy/sites-enabled/api.example.com.caddy
sudo systemctl reload caddy
```

Site types: `api` (reverse proxy), `spa`, `static`, `laravel`, `nextjs`.

### Which script for what?

| Need | Script | Effect |
|------|--------|--------|
| **New code/binary** | `sudo bash /opt/shared/scripts/deploy-<app>.sh <source>` | Creates `releases/<ts>/`, switches `current`, reloads service |
| **Change port, env, entry, Caddy domain** | `sudo bash 05a/b/c/d-deploy-*.sh` | Detects existing app, regenerates `.env` / systemd / Caddy block |
| **Add/modify a Caddy domain** | `sudo bash 02b-add-caddy-site.sh [domain]` | Writes `sites-enabled/<domain>.caddy`, reloads Caddy |
| **Rollback** | `sudo ln -sfn /opt/<app>/releases/<old> /opt/<app>/current && sudo systemctl restart <app>` | Atomic symlink switch |
| **Server state** | `sudo bash 00-list-apps.sh` | Full overview |
| **Initial install of new app** | `sudo bash 05a/b/c/d-deploy-*.sh` | Creates everything from scratch |

All `05*` scripts are **idempotent**: rerunning them on an existing app
updates only `.env`, systemd config, and Caddy block — code is untouched.

### Deployed app structure

```
/opt/<app>/
├── releases/
│   ├── 20260101_143022/        # release N-2
│   ├── 20260101_150811/        # release N-1
│   └── 20260101_161533/        # current
├── shared/
│   ├── .env                    # persists across releases
│   ├── uploads/                # user folders (symlinked)
│   └── storage/                # Laravel
├── logs/
│   └── systemd.log
└── current → releases/20260101_161533
```

### Troubleshooting

```bash
systemctl status <app>
journalctl -u <app> -f
tail -f /opt/<app>/logs/systemd-err.log
tail -f /var/log/caddy/<domain_with_underscores>.log
caddy validate --config /etc/caddy/Caddyfile
ls -lt /opt/<app>/releases/
```

</details>

---

<details>
<summary><h2 id="-français">🇫🇷 Français</h2></summary>

### Pourquoi ce projet ?

Industrialiser le déploiement de plusieurs applications sur un **seul VPS
Ubuntu**, sans Docker/Kubernetes et sans dépendre d'un PaaS tiers payant.

Concrètement, ce lot de scripts résout :

1. **Setup serveur reproductible** — sécurisation, swap, Caddy, bases de
   données en quelques commandes, jamais à refaire manuellement
2. **Déploiement standardisé par framework** — chaque app obtient son
   utilisateur système, son `.env`, son service systemd, son bloc Caddy et son
   propre script de déploiement, généré automatiquement
3. **Mises à jour zero-downtime** — système `releases/<timestamp>/` + symlink
   `current`, rollback en une commande
4. **Isolation entre apps** — un user dédié par app, droits 750, sandbox systemd
5. **Migrations DB intégrées au pipeline** — la commande de migration
   (Prisma / Sequelize / TypeORM / Knex / Drizzle / artisan / sqlx) tourne
   automatiquement avant chaque swap ; échec ⇒ swap annulé
6. **Préservation des données utilisateurs** — les dossiers comme `uploads/`
   sont symlinkés depuis `shared/`, jamais écrasés lors d'une mise à jour
7. **Diagnostic rapide** — un script affiche l'état complet du serveur (apps,
   ports, sites Caddy, services), un menu interactif gère les ops courantes
   d'ORM
8. **Caddy modulaire** — un fichier par site (`sites-enabled/*.caddy`)
9. **Résilience** — health check post-déploiement avec rollback automatique si
   le service ne redémarre pas, fallback automatique sur l'entry point si le
   chemin de build varie (`dist/main.js` vs `dist/src/main.js`)
10. **Optimisé pour petites VM** — swap automatique, limites mémoire Node
    explicites, pas de PM2 superflu (systemd direct)

En une phrase : **un PaaS minimaliste sur VPS**, opinionné pour la stack
Node/Rust/Laravel/Static, conçu pour héberger plusieurs apps sur le même
serveur sans complexité inutile.

### Ordre d'exécution (première installation)

```bash
sudo bash 01-initial-setup.sh        # utilisateur admin, SSH, UFW, fail2ban, swap
sudo bash 02-install-caddy.sh        # Caddy + PHP-FPM (structure sites-enabled/)
sudo bash 03-install-database.sh     # menu : PG, MySQL, MariaDB, Mongo, Redis, Supabase
sudo bash 06-adminer-hardening.sh    # Adminer sur port local + protection Caddy
```

#### Script 03 : menu de bases de données

Plusieurs bases peuvent **coexister sur le même serveur**. Pour chacune :
choix de version, mot de passe root généré, bind 127.0.0.1, premières bases
applicatives, backups quotidiens (rotation 7j + 4 semaines), UI web optionnelle.

| # | Base | Versions | UI web associée |
|---|------|----------|-----------------|
| 1 | PostgreSQL | 13, 14, 15, 16, 17 | Adminer |
| 2 | MySQL (Oracle) | 8.0, 8.4 LTS | Adminer + phpMyAdmin |
| 3 | MariaDB | 10.6, 10.11, 11.4 LTS | Adminer + phpMyAdmin |
| 4 | MongoDB | 6.0, 7.0, 8.0 | Mongo Express |
| 5 | Redis | 6, 7 | RedisInsight |
| 6 | Supabase (BaaS) | dernier stable (Docker) | Studio (intégré) |

Toutes les UIs web sont exposées via Caddy avec basic auth (le script demande
un domaine et un identifiant à la fin de chaque install). Tous les credentials
sont sauvegardés dans `/root/db-credentials/<base>-<date>.txt` (chmod 600).

### Voir l'état du serveur

```bash
sudo bash 00-list-apps.sh   # apps, sites Caddy, services, ports
```

Ce script est aussi appelé automatiquement (en mode court) au début des scripts
`02b-add-caddy-site.sh` et `05*` pour t'aider à éviter les collisions de noms
ou de ports avant de saisir tes valeurs.

### Déploiement d'une app (répéter par app)

| Script | Framework | Entry / Serveur |
|--------|-----------|-----------------------|
| `05a-deploy-node.sh` | NestJS | `dist/main.js` ou `dist/src/main.js` via systemd direct (auto-fallback) |
| `05a-deploy-node.sh` | Express | entry personnalisable (src/server.js, app.js, …) via systemd |
| `05a-deploy-node.sh` | Next.js (SSR) | `next start` via systemd |
| `05b-deploy-rust.sh` | Rust | binaire natif via systemd |
| `05c-deploy-laravel.sh` | Laravel | PHP-FPM + Caddy `php_fastcgi` |
| `05d-deploy-static.sh` | HTML/CSS, SPA, Next.js export | Caddy `file_server` |

> **Pas de PM2.** Tous les services Node tournent en systemd direct
> (`Type=simple`, `ExecStart=/usr/bin/node …`). Évite la double supervision
> systemd+PM2 qui causait des erreurs `spawn EACCES`.

#### Auto-détection de l'entry point (NestJS / Express)

Le build NestJS produit parfois `dist/main.js`, parfois `dist/src/main.js`
(selon ta structure `tsconfig.json`). À chaque déploiement, le script vérifie
que l'entry configuré existe ; sinon il cherche un fallback parmi :

```
dist/main.js, dist/src/main.js, dist/index.js, dist/app.js,
src/main.js, src/server.js, src/app.js, src/index.js,
server.js, app.js, index.js
```

Si un fallback est trouvé, le `ExecStart` du service systemd est mis à jour
automatiquement et `daemon-reload` est appelé.

#### Dossiers persistants entre releases

À l'installation des scripts `05a/05b/05c`, tu peux déclarer des dossiers à
**préserver entre les déploiements** (uploads utilisateurs, fichiers attachés…).

Ils sont stockés dans `/opt/<app>/shared/<dossier>/` et **symlinkés** dans
chaque nouvelle release. La première fois, si le dossier existe dans la release
avec du contenu (ex: `public/uploads/` venant du repo), son contenu est migré
dans `shared/` automatiquement.

| Framework | Dossiers gérés par défaut | Dossiers additionnels typiques |
|-----------|-----------------------|---------------------|
| Node | aucun | `uploads`, `public/uploads`, `attachments` |
| Rust | aucun | `uploads`, `data`, `attachments` |
| Laravel | `storage/`, `bootstrap/cache/` | `public/uploads`, `public/storage` |

#### DevDependencies à garder en production (Node)

Certaines apps utilisent `ts-node` en production (ex : `prisma db seed` qui
exécute `ts-node prisma/seed.ts`). Le script `05a` te demande la liste de
devDependencies à **réinstaller après** `npm prune --omit=dev`.

Exemple pour Prisma + ts-node : `ts-node typescript @types/node`

#### Approche : build sur le serveur

Pour les apps **Node** et **Laravel**, tu envoies uniquement le **code
source** — le serveur se charge d'installer les dépendances et de compiler.
Plus propre, plus rapide à uploader, évite les mismatches d'architecture/version.

| Framework | Ce que tu envoies | Ce que le serveur fait |
|-----------|-------------------|-----------------------|
| NestJS | source (sans `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Express (JS) | source (sans `node_modules/`) | `npm ci` → migrations → `npm prune --omit=dev` |
| Express (TS) | source (sans `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Next.js SSR | source (sans `.next/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Laravel | source (sans `vendor/`, `node_modules/`) | `composer install --no-dev` → `artisan migrate --force` → cache |
| Rust | binaire pré-compilé (ou dossier avec migrations) | copie + swap (pas de build serveur) |

#### Exemple : déploiement d'une version

```bash
# Sur ta machine de dev — envoi du source brut
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.next' \
  --exclude '.git' \
  --exclude '.env*' \
  -e 'ssh -p <PORT>' \
  ./ admin@<IP>:/tmp/monapi-src/

# Sur le serveur — build + migrations + swap
sudo bash /opt/shared/scripts/deploy-monapi.sh /tmp/monapi-src
```

Le script de déploiement exécute dans l'ordre :
1. Copie le source dans `/opt/<app>/releases/<timestamp>/`
2. Symlink `shared/.env` + dossiers persistants (`uploads/`, etc.)
3. `npm ci --include=dev` (toutes les deps pour permettre le build)
4. Commande de build (`npm run build`, etc.) si configurée
5. **Migrations DB** (si configurées)
6. `npm prune --omit=dev` (retire les devDependencies)
7. Réinstalle les devDeps marquées « à garder » (ts-node, etc.)
8. Vérifie que l'entry point existe (auto-fallback NestJS)
9. Bascule `current` → nouvelle release (atomique)
10. `systemctl restart` + **health check** (rollback auto si KO)
11. Purge des vieilles releases (garde les 5 dernières)

> Si le build, la migration **ou** le démarrage du service échoue, l'ancienne
> release reste active. La release ratée est conservée pour debug.

#### Migrations DB

Chaque script `05a/05b/05c` demande une commande de migration à l'installation :

| Stack | Commande typique |
|-------|-------------------|
| Prisma | `npx prisma migrate deploy` |
| Sequelize | `npx sequelize-cli db:migrate --env production` |
| TypeORM | `npx typeorm migration:run -d dist/data-source.js` |
| Knex | `npx knex migrate:latest --env production` |
| Drizzle | `npx drizzle-kit migrate` |
| Laravel | `php artisan migrate --force` *(auto, intégré)* |
| sqlx (Rust) | `sqlx migrate run` |

#### DB Manager — menu interactif (Node uniquement)

Si tu choisis un ORM à l'installation (Prisma, Sequelize, TypeORM, Knex,
Drizzle), le script `05a` génère aussi un **DB Manager** dédié :

```bash
sudo bash /opt/shared/scripts/<app>-db.sh
```

C'est un menu numéroté avec **toutes** les commandes ORM disponibles
(migrations, seeds, studio, génération, rollback…). L'utilisateur tape
juste un chiffre.

```
════════════════════════════════════════════════
  DB Manager — monapi (sequelize)
════════════════════════════════════════════════

  MIGRATIONS
   1) db:migrate           (exécuter les migrations en attente)
   2) db:migrate:status    (voir l'état)
   3) db:migrate:undo      (rollback la dernière)
   4) db:migrate:undo:all  (rollback toutes — DESTRUCTIF)

  SEEDS
   5) db:seed              (choisir : tous ou un seul)
   6) db:seed:undo         (rollback dernier seed)
   7) db:seed:undo:all     (rollback tous les seeds)

  MODÈLES
   8) model:generate       (générer un nouveau modèle — interactif)

   c) Commande npm script personnalisée
   r) Recharger l'app (systemctl reload)
   l) Voir les logs récents
   q) Quitter

Ton choix : 5
```

Quand tu choisis l'option **seed**, un sous-menu liste tous les fichiers de
`seeders/` :

```
Choisis un fichier :
   0) ⭐ Tous (exécution séquentielle)
   1) 20260101000000-create-users.js
   2) 20260101000001-create-roles.js
   3) 20260101000002-permissions.js

  Choix : 2
```

Tu peux exécuter **tous** les seeds (0) ou un **seul** (numéro). Les
opérations destructives demandent une confirmation explicite (taper
`CONFIRMER`).

### Caddy — gestion des sites

Config modulaire :

```
/etc/caddy/
├── Caddyfile                    # config principale (importe sites-enabled/)
├── snippets/
│   ├── security-headers.caddy
│   └── logging.caddy
└── sites-enabled/
    ├── api.exemple.com.caddy
    ├── app.exemple.com.caddy
    └── dbadmin.exemple.com.caddy
```

```bash
# Ajouter un site
sudo bash 02b-add-caddy-site.sh api.exemple.com

# Modifier
sudo nano /etc/caddy/sites-enabled/api.exemple.com.caddy
sudo systemctl reload caddy

# Supprimer
sudo rm /etc/caddy/sites-enabled/api.exemple.com.caddy
sudo systemctl reload caddy
```

Types de sites : `api` (reverse proxy), `spa`, `static`, `laravel`, `nextjs`.

### Quel script pour quoi ?

| Besoin | Script | Effet |
|--------|--------|-------|
| **Nouveau code / binaire** | `sudo bash /opt/shared/scripts/deploy-<app>.sh <source>` | Crée `releases/<ts>/`, bascule `current`, reload service |
| **Changer port, env, entry, domaine Caddy** | `sudo bash 05a/b/c/d-deploy-*.sh` | Détecte l'app, régénère `.env` / systemd / Caddy |
| **Ajouter/modifier un domaine Caddy** | `sudo bash 02b-add-caddy-site.sh [domaine]` | Écrit `sites-enabled/<domaine>.caddy` |
| **Rollback** | `sudo ln -sfn /opt/<app>/releases/<ancien> /opt/<app>/current && sudo systemctl restart <app>` | Bascule atomique |
| **État du serveur** | `sudo bash 00-list-apps.sh` | Récap complet |
| **Installation initiale d'une nouvelle app** | `sudo bash 05a/b/c/d-deploy-*.sh` | Crée tout de zéro |

Tous les scripts `05*` sont **idempotents** : relancés sur une app existante,
ils ne modifient que `.env`, systemd et le bloc Caddy — le code n'est pas
touché.

### Structure d'une app déployée

```
/opt/<app>/
├── releases/
│   ├── 20260101_143022/        # release N-2
│   ├── 20260101_150811/        # release N-1
│   └── 20260101_161533/        # release actuelle
├── shared/
│   ├── .env                    # persiste entre releases
│   ├── uploads/                # dossiers utilisateurs (symlinkés)
│   └── storage/                # Laravel
├── logs/
│   └── systemd.log
└── current → releases/20260101_161533
```

### Dépannage

```bash
systemctl status <app>
journalctl -u <app> -f
tail -f /opt/<app>/logs/systemd-err.log
tail -f /var/log/caddy/<domaine_avec_underscores>.log
caddy validate --config /etc/caddy/Caddyfile
ls -lt /opt/<app>/releases/
```

</details>

---

<details>
<summary><h2 id="-changelog">📝 Changelog</h2></summary>

Format inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [SemVer](https://semver.org/).

### [0.5.0] — 2026-04-18 — Multi-database installer

#### Added
- **`03-install-database.sh`** — Unified menu installer for 6 database engines
  that can coexist on the same server :
  - PostgreSQL 13/14/15/16/17 (PGDG repo)
  - MySQL Oracle 8.0/8.4 LTS (official Oracle repo)
  - MariaDB 10.6/10.11/11.4 LTS (official MariaDB repo)
  - MongoDB 6.0/7.0/8.0 (official Mongo repo)
  - Redis 6/7 (official Redis repo)
  - Supabase self-hosted (Docker Compose: postgres + auth + realtime + storage + studio)
- **Per-DB hardening**: bind 127.0.0.1, generated 32-char root password,
  optional N application DBs + dedicated users
- **Auto backups**: daily cron at 3am to `/var/backups/<db>/`, rotation 7
  daily + 4 weekly snapshots (Sunday), gzip compression, log file
- **Optional web UIs** (explicit confirmation): Adminer, phpMyAdmin, Mongo
  Express (Docker), RedisInsight (Docker), all behind Caddy basic auth
- **Helpers**: `ensure_port_free`, `ensure_caddy_ui`, `setup_backup_cron`,
  `gen_password`, `save_creds`, `confirm`
- Status sub-menu showing installed DBs and credential files

#### Removed
- `03-install-postgresql.sh` (replaced by `03-install-database.sh` with
  PostgreSQL as menu option 1)

### [0.4.0] — 2026-04-18 — Bilingual documentation

#### Added
- README "Why this project?" section (10 reasons + tagline)
- English README (`README.en.md`) with full content
- Cross-link FR ↔ EN at the top of each doc
- Generic examples (`monapi`/`myapi`) instead of real project names

### [0.3.0] — 2026-04-18 — Diagnostic-driven hardening

#### Changed
- **Drop PM2 entirely for Node apps** — replaced by direct systemd
  (`Type=simple`, `ExecStart=/usr/bin/node …`). Avoids dual supervision and
  fixes the `spawn /usr/bin/node EACCES` error class.
- Logrotate now uses `copytruncate` instead of `pm2 reloadLogs`
- README updated to reflect systemd-direct architecture

#### Added
- **Entry point auto-detection** at deploy time — if the configured `ENTRY`
  doesn't exist after build, search through 11 common locations
  (`dist/main.js`, `dist/src/main.js`, `src/server.js`, …) and update the
  systemd `ExecStart` automatically.
- **Persistent folders** for Node, Rust, Laravel — declare folders to
  preserve across releases (`uploads/`, `public/storage`, etc.). Stored in
  `/opt/<app>/shared/<dir>/` and symlinked into each new release. First-run
  content migration if `shared/` is empty.
- **`KEEP_DEV_DEPS`** option for Node — re-installs specified
  devDependencies after `npm prune --omit=dev` (use case: `ts-node` for
  `prisma db seed` in production).
- **Health check + automatic rollback** post-deploy — if `systemctl
  is-active` fails 3 times after restart, atomically symlink-back to the
  previous release and restart.
- Initial swap creation in `01-initial-setup.sh` (2 GB swapfile + swappiness=10)

### [0.2.0] — 2026-04-18 — Multi-framework refactor

#### Added
- **`00-list-apps.sh`** — server state overview (apps in `/opt/`, framework
  auto-detection, ports, Caddy sites, systemd services). Called automatically
  in short mode at the start of `02b` and `05*` scripts to prevent name/port
  collisions.
- **`02-install-caddy.sh`** — refactored: only installs Caddy + PHP-FPM and
  prepares `sites-enabled/` modular structure (no more per-site questions).
- **`02b-add-caddy-site.sh`** — add/update a Caddy site independently of any
  app, with type selection (`api`, `spa`, `static`, `laravel`, `nextjs`) and
  optional basic auth.
- **`05a-deploy-node.sh`** — unified Node deployer with framework selector
  (NestJS/Express/Next.js), entry point question, build command, ORM
  selection, migration command, persistent folders, ORM-specific DB Manager
  generator.
- **`05b-deploy-rust.sh`** — Rust deployer (systemd, binary or
  binary-with-assets mode).
- **`05c-deploy-laravel.sh`** — Laravel deployer (PHP-FPM, Composer install
  on server, `artisan migrate --force` integrated, optional queue worker).
- **`05d-deploy-static.sh`** — HTML/SPA/Next.js export deployer with smart
  cache headers per file type.
- **DB Manager** — interactive numbered menu generated per app (Prisma,
  Sequelize, TypeORM, Knex, Drizzle), with sub-menu for picking individual
  seeds (0 = all, N = single file). Destructive ops require `CONFIRMER`.
- **Build-on-server workflow** — send raw source via rsync (no `node_modules`,
  `dist`, `.next`); the server runs `npm ci --include=dev`, `npm run build`,
  migrations, then `npm prune --omit=dev`.

#### Changed
- **`releases/<timestamp>/` + `current` symlink** for all deployers — atomic
  zero-downtime swap, easy rollback, automatic purge keeping last 5.
- Caddy config moved to `Caddyfile` + `sites-enabled/*.caddy` (one file per
  domain) + `snippets/*.caddy` (shared security-headers, logging).
- Memory-limited `npm ci/install` (`NODE_OPTIONS=--max-old-space-size=1024`)
  to prevent OOM on small VMs.
- `npm ci` falls back to `npm install` if lock file is desynchronized
  cross-platform (mac→linux platform-specific deps).

#### Removed
- `04-deploy-rust-app.sh` and `05-deploy-node-app.sh` (replaced by `05a/b/c/d`)

### [0.1.0] — 2026-04-XX — Initial release

#### Added
- `01-initial-setup.sh` — admin user, SSH hardening, UFW, fail2ban
- `02-install-caddy.sh` — Caddy install with per-app reverse proxy
- `03-install-postgresql.sh` — PostgreSQL 16 with auto tuning, multi-DB
- `04-deploy-rust-app.sh` — Rust app deployment with systemd
- `05-deploy-node-app.sh` — NestJS app deployment with PM2
- `06-adminer-hardening.sh` — Adminer on local port behind Caddy basic auth

</details>

---

<sub>Maintainer: <a href="mailto:goncoolio@gmail.com">Ousmane Coulibaly</a></sub>
