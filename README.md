# Config serveur Ubuntu — HTIC-NETWORKS

Scripts d'installation et de déploiement pour un serveur Ubuntu 24.04 mutualisé
(plusieurs apps, Caddy HTTPS, PostgreSQL, Adminer).

> 🇬🇧 **English version** : voir [README.en.md](README.en.md)

## Pourquoi ce projet ?

Industrialiser le déploiement de plusieurs applications sur un **seul VPS
Ubuntu**, sans Docker/Kubernetes et sans dépendre d'un PaaS tiers payant.

Concrètement, ce lot de scripts résout :

1. **Setup serveur reproductible** — sécurisation, swap, Caddy, PostgreSQL en
   quelques commandes, jamais à refaire manuellement
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
   d'ORM (migrations, seeds, studio)
8. **Caddy modulaire** — un fichier par site (`sites-enabled/*.caddy`),
   ajout/modification d'un domaine sans toucher aux autres
9. **Résilience** — health check post-déploiement avec rollback automatique si
   le service ne redémarre pas, fallback automatique sur l'entry point si le
   chemin de build varie (`dist/main.js` vs `dist/src/main.js`)
10. **Optimisé pour petites VM** — swap automatique, limites mémoire Node
    explicites, pas de PM2 superflu (systemd direct)

En une phrase : **un PaaS minimaliste sur VPS**, opinionné pour la stack
Node/Rust/Laravel/Static, conçu pour héberger plusieurs apps sur le même
serveur sans complexité inutile.

## Ordre d'exécution (première installation)

```bash
sudo bash 01-initial-setup.sh        # utilisateur admin, SSH, UFW, fail2ban, swap
sudo bash 02-install-caddy.sh        # Caddy + PHP-FPM (structure sites-enabled/)
sudo bash 03-install-database.sh     # menu : PG, MySQL, MariaDB, Mongo, Redis, Supabase
sudo bash 06-adminer-hardening.sh    # Adminer sur port local + protection Caddy
```

### Script 03 : menu de bases de données

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
# Nom : monapi
# Port : 3002
# Entry point : dist/src/main.js   (ou dist/main.js — auto-fallback)
# Domaine Caddy : api.exemple.com
```

Le script configure :
- utilisateur système dédié `monapi`
- `/opt/monapi/` avec `releases/`, `shared/.env`, `current` symlink
- service systemd direct (`Type=simple`, `node $ENTRY`)
- Caddy reverse proxy (si domaine fourni)
- script de déploiement `/opt/shared/scripts/deploy-monapi.sh`
- DB Manager `/opt/shared/scripts/monapi-db.sh` (si ORM choisi)

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
ls -lt /opt/<app>/releases/

# Rollback vers une version précédente
sudo ln -sfn /opt/<app>/releases/20260101_143022 /opt/<app>/current
sudo systemctl restart <app>
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
| **Changer port, env vars, entry point, domaine Caddy** | `sudo bash 05a/b/c/d-deploy-*.sh` | Détecte l'app existante, régénère `.env` / systemd / bloc Caddy — **ne touche pas au code déployé** |
| **Ajouter ou modifier un domaine Caddy** (sans toucher à l'app) | `sudo bash 02b-add-caddy-site.sh [domaine]` | Écrit uniquement `sites-enabled/<domaine>.caddy`, reload Caddy |
| **Rollback vers une release précédente** | `sudo ln -sfn /opt/<app>/releases/<ancien> /opt/<app>/current && sudo systemctl reload <app>` | Bascule atomique du symlink |
| **Voir l'état du serveur** (apps, ports, sites) | `sudo bash 00-list-apps.sh` | Récap complet |
| **Installation initiale d'une nouvelle app** | `sudo bash 05a/b/c/d-deploy-*.sh` (si nom encore inexistant dans `/opt/`) | Crée tout de zéro |

### Idempotence des scripts `05*`

Tous les scripts `05a/b/c/d` sont **idempotents**. Si l'app existe déjà ils
affichent `[AVERT] App <nom> existe déjà → mode MISE À JOUR de la config` et
mettent à jour uniquement :
- le fichier `.env` (dans `shared/`)
- la config systemd
- le bloc Caddy (si domaine fourni)

Les releases existantes et le symlink `current` ne sont pas touchés — seul le
prochain `deploy-<app>.sh` créera une nouvelle release avec du nouveau code.

## Structure d'une app déployée

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

## Dépannage

```bash
# Logs par app
systemctl status <app>
journalctl -u <app> -f
tail -f /opt/<app>/logs/systemd-err.log

# Logs Caddy par site
tail -f /var/log/caddy/<domaine_avec_underscores>.log

# Valider Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# Liste des releases
ls -lt /opt/<app>/releases/
```
