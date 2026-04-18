# Config serveur Ubuntu — HTIC-NETWORKS

Scripts d'installation et de déploiement pour un serveur Ubuntu 24.04 mutualisé
(plusieurs apps, Caddy HTTPS, PostgreSQL, Adminer).

## Ordre d'exécution (première installation)

```bash
sudo bash 01-initial-setup.sh        # utilisateur admin, SSH, UFW, fail2ban
sudo bash 02-install-caddy.sh        # Caddy + PHP-FPM (structure sites-enabled/)
sudo bash 03-install-postgresql.sh   # PostgreSQL 16
sudo bash 06-adminer-hardening.sh    # Adminer sur port local + protection Caddy
```

## Voir l'état du serveur

```bash
sudo bash 00-list-apps.sh   # apps, sites Caddy, services, ports
```

Ce script est aussi appelé automatiquement (en mode court) au début des scripts
`02b-add-caddy-site.sh` et `05*` pour t'aider à éviter les collisions de noms
ou de ports avant de saisir tes valeurs.

## Déploiement d'une app (répéter par app)

Choisis le script selon le framework :

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

### Auto-détection de l'entry point (NestJS / Express)

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

### Dossiers persistants entre releases

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

### DevDependencies à garder en production (Node)

Certaines apps utilisent `ts-node` en production (ex: `prisma db seed` qui
exécute `ts-node prisma/seed.ts`). Le script `05a` te demande la liste de
devDependencies à **réinstaller après** `npm prune --omit=dev`.

Exemple pour Prisma + ts-node : `ts-node typescript @types/node`

### Exemple : app NestJS

```bash
sudo bash 05a-deploy-node.sh
# Framework : 1 (NestJS)
# Nom : munipay-api
# Port : 3002
# Domaine Caddy : api.exemple.com
```

Le script configure :
- utilisateur système dédié `munipay-api`
- `/opt/munipay-api/` avec `releases/`, `shared/.env`, `current` symlink
- PM2 via systemd (reload zero-downtime)
- Caddy reverse proxy (si domaine fourni)
- Script de déploiement `/opt/shared/scripts/deploy-munipay-api.sh`

### Approche : build sur le serveur

Pour les apps **Node (NestJS / Express / Next.js)** et **Laravel**, tu envoies
uniquement le **code source** — le serveur se charge d'installer les dépendances
et de compiler. C'est plus propre, plus rapide à uploader, et évite les
mismatches d'architecture/version.

| Framework | Ce que tu envoies | Ce que le serveur fait |
|-----------|-------------------|-----------------------|
| NestJS | source (sans `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Express (JS) | source (sans `node_modules/`) | `npm ci` → migrations → `npm prune --omit=dev` |
| Express (TS) | source (sans `dist/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Next.js SSR | source (sans `.next/`, `node_modules/`) | `npm ci` → `npm run build` → migrations → `npm prune --omit=dev` |
| Laravel | source (sans `vendor/`, `node_modules/`) | `composer install --no-dev` → `artisan migrate --force` → cache |
| Rust | binaire pré-compilé (ou dossier avec migrations) | copie + swap (pas de build serveur) |

### Exemple : déploiement d'une version

```bash
# Sur ta machine de dev — envoi du source brut
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.next' \
  --exclude '.git' \
  --exclude '.env*' \
  -e 'ssh -p <PORT>' \
  ./ admin@<IP>:/tmp/munipay-api-src/

# Sur le serveur — build + migrations + swap
sudo bash /opt/shared/scripts/deploy-munipay-api.sh /tmp/munipay-api-src
```

Le script de déploiement exécute dans l'ordre :
1. Copie le source dans `/opt/munipay-api/releases/<timestamp>/`
2. Link symbolique vers `shared/.env`
3. `npm ci --include=dev` (toutes les deps pour permettre le build)
4. Commande de build (`npm run build`, etc.) si configurée
5. **Migrations DB** (si configurées)
6. `npm prune --omit=dev` (retire les devDependencies)
7. Bascule `current` → nouvelle release (atomique)
8. Reload PM2 (zero-downtime)
9. Purge des vieilles releases (garde les 5 dernières)

> Si le build **ou** la migration échoue, le swap est **annulé** — l'ancienne
> release reste active. La release ratée est conservée pour debug.

### Migrations DB

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

Pour **changer** la commande de migration d'une app existante, relance le
script `05a/b/c` correspondant — il détecte l'app existante et régénère
`deploy-<app>.sh` avec la nouvelle commande.

### DB Manager — menu interactif (Node uniquement)

Si tu choisis un ORM à l'installation (Prisma, Sequelize, TypeORM, Knex,
Drizzle), le script `05a` génère aussi un **DB Manager** dédié :

```bash
sudo bash /opt/shared/scripts/<app>-db.sh
```

C'est un menu numéroté avec **toutes** les commandes ORM disponibles
(migrations, seeds, studio, génération, rollback…). L'utilisateur tape
juste un chiffre.

#### Exemple (Sequelize)

```
════════════════════════════════════════════════
  DB Manager — api-wii-saas (sequelize)
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

Quand tu choisis l'option **seed** (ex : option 5 pour Sequelize), un
sous-menu liste tous les fichiers de `seeders/` :

```
Choisis un fichier :
   0) ⭐ Tous (exécution séquentielle)
   1) 20260101000000-create-users.js
   2) 20260101000001-create-roles.js
   3) 20260101000002-permissions.js

  Choix : 2
```

Tu peux exécuter **tous** les seeds (0) ou un **seul** (numéro).

| Commun à tous les ORM | Description |
|------------------------|-------------|
| `c` | Lancer un script `npm run <X>` du `package.json` |
| `r` | `systemctl reload <app>` |
| `l` | Derniers logs `journalctl -u <app>` |
| `q` | Quitter |

Les opérations destructives (rollback all, drop, etc.) demandent une
confirmation explicite (taper `CONFIRMER`).

### Rollback

```bash
# Liste des releases
ls -lt /opt/munipay-api/releases/

# Rollback vers une version précédente
sudo ln -sfn /opt/munipay-api/releases/20260417_143022 /opt/munipay-api/current
sudo systemctl reload munipay-api
```

## Caddy — gestion des sites

La config Caddy est modulaire :

```
/etc/caddy/
├── Caddyfile                    # config principale (importe sites-enabled/)
├── snippets/
│   ├── security-headers.caddy   # headers sécurité partagés
│   └── logging.caddy            # logging JSON
└── sites-enabled/
    ├── api.exemple.com.caddy
    ├── app.exemple.com.caddy
    └── dbadmin.exemple.com.caddy
```

### Ajouter un site sans redéployer l'app

```bash
sudo bash 02b-add-caddy-site.sh
# ou directement :
sudo bash 02b-add-caddy-site.sh api.exemple.com
```

Types de sites : `api` (reverse proxy), `spa`, `static`, `laravel`, `nextjs`.

### Modifier/supprimer un site

```bash
# Modifier
sudo nano /etc/caddy/sites-enabled/api.exemple.com.caddy
sudo systemctl reload caddy

# Ou ré-exécuter le script (écrase)
sudo bash 02b-add-caddy-site.sh api.exemple.com

# Supprimer
sudo rm /etc/caddy/sites-enabled/api.exemple.com.caddy
sudo systemctl reload caddy
```

## Quel script pour quoi ?

Deux types de mises à jour — ne les confonds pas :

| Besoin | Script à utiliser | Effet |
|--------|-------------------|-------|
| **Nouveau code / binaire** (nouvelle version de l'app) | `sudo bash /opt/shared/scripts/deploy-<app>.sh <source>` | Crée `releases/<timestamp>/`, bascule `current`, reload service (zero-downtime) |
| **Changer port, env vars, entry point, domaine Caddy** | `sudo bash 05a/b/c/d-deploy-*.sh` | Détecte l'app existante, régénère `.env` / PM2 / systemd / bloc Caddy — **ne touche pas au code déployé** |
| **Ajouter ou modifier un domaine Caddy** (sans toucher à l'app) | `sudo bash 02b-add-caddy-site.sh [domaine]` | Écrit uniquement `sites-enabled/<domaine>.caddy`, reload Caddy |
| **Rollback vers une release précédente** | `sudo ln -sfn /opt/<app>/releases/<ancien> /opt/<app>/current && sudo systemctl reload <app>` | Bascule atomique du symlink |
| **Voir l'état du serveur** (apps, ports, sites) | `sudo bash 00-list-apps.sh` | Récap complet |
| **Installation initiale d'une nouvelle app** | `sudo bash 05a/b/c/d-deploy-*.sh` (si nom encore inexistant dans `/opt/`) | Crée tout de zéro |

### Idempotence des scripts `05*`

Tous les scripts `05a/b/c/d` sont **idempotents**. Si l'app existe déjà ils
affichent `[AVERT] App <nom> existe déjà → mode MISE À JOUR de la config` et
mettent à jour uniquement :
- le fichier `.env` (dans `shared/`)
- la config PM2 / systemd
- le bloc Caddy (si domaine fourni)

Les releases existantes et le symlink `current` ne sont pas touchés — seul le
prochain `deploy-<app>.sh` créera une nouvelle release avec du nouveau code.

## Structure d'une app déployée

```
/opt/<app>/
├── releases/
│   ├── 20260417_143022/        # release N-2
│   ├── 20260417_150811/        # release N-1
│   └── 20260417_161533/        # release actuelle
├── shared/
│   ├── .env                    # persiste entre releases
│   ├── ecosystem.config.js     # config PM2 (Node)
│   └── storage/                # Laravel
├── logs/
│   ├── out.log
│   ├── err.log
│   └── systemd.log
├── current → releases/20260417_161533
└── .pm2/                       # PM2 home (Node)
```

## Dépannage

```bash
# Logs par app
systemctl status <app>
journalctl -u <app> -f
tail -f /opt/<app>/logs/err.log

# Logs Caddy par site
tail -f /var/log/caddy/<domaine_avec_underscores>.log

# Valider Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# Liste des releases
ls -lt /opt/<app>/releases/
```
