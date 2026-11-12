# Capital Challenge

Quiz multijoueur en temps réel sur les capitales du monde.

- **Frontend** : HTML, CSS et JavaScript natifs (modules ES), sans framework ni étape de build.
- **Backend** : Supabase uniquement — Auth, PostgreSQL, Realtime et fonctions SQL `SECURITY DEFINER`.
- **Hébergement** : compatible GitHub Pages (routage par hash, aucun serveur à maintenir).
- **Périmètre** : 195 pays (193 membres de l'ONU + Vatican + Palestine), 2 à 9 joueurs par
  salle, 15 à 55 pays par session, joker orthographique, missions quotidiennes et
  portefeuille virtuel.

> Les crédits sont **virtuels** : non retirables, non convertibles en argent réel, non transférables.

---

## Installation

### 1. Supabase — exécuter les fichiers SQL **dans cet ordre**

Ouvrir **Supabase → SQL Editor**, puis coller et exécuter chaque fichier, l'un après l'autre :

| # | Fichier | Contenu |
|---|---------|---------|
| 1 | `supabase/sql/01_schema.sql` | Tables, index, RLS, portefeuille, profils, trophées, réglages |
| 2 | `supabase/sql/02_seed_pays.sql` | Les 195 pays (FR/EN, capitales, notes) |
| 3 | `supabase/sql/03_salles.sql` | Salles : créer, rejoindre, prêt, départ, frais d'entrée |
| 4 | `supabase/sql/04_moteur.sql` | Correction, manches, révélation, classement, gains |
| 5 | `supabase/sql/05_missions.sql` | Missions quotidiennes : catalogue + moteur |
| 6 | `supabase/sql/06_achats.sql` | Packs et achats (boutique fermée par défaut) |
| 7 | `supabase/sql/07_correctif.sql` | Correctif final : missions, chrono 15 s, achats fermés, diagnostic |
| 8 | `supabase/sql/08_missions_fix.sql` | **Réparation des missions** : structure, catalogue, moteur, test réel |
| 9 | `supabase/sql/09_missions_rebuild.sql` | Reconstruction propre des tables de missions (sauvegarde + test réel) |
| 10 | `supabase/sql/10_pick_inscription.sql` | **Choix du pays 30 s (validation fiabilisée) + inscription sans e-mail** |
| 11 | `supabase/sql/11_salles_abandonnees.sql` | Ferme les parties abandonnées, rembourse la mise, débloque la création de salle |
| 12 | `supabase/sql/12_round_secrets.sql` | **Corrige la table `round_secrets`** (colonne `secret` manquante) + audit des colonnes |
| 13 | `supabase/sql/13_manches_uuid.sql` | **Corrige les identifiants de manche** (`rounds.id` en bigint → uuid) + remboursement des parties en cours |

Chaque fichier est **autonome et ré-exécutable** : on peut le relancer sans risque, aucune
donnée n'est supprimée. `08_missions_fix.sql` reconstruit les tables de missions si elles
viennent d'une ancienne version (elles sont d'abord sauvegardées en `*_backup_...`), puis
teste la génération sur les vrais comptes et affiche le résultat :

```
structure = compatible | faciles = 4 | moyennes = 4 | difficiles = 4
comptes_ok = (nombre de comptes) | comptes_ko = 0 | premiere_erreur = aucune
missions_du_jour = (nombre de comptes × 3)
```

`10_pick_inscription.sql` règle les deux derniers blocages :

- **choix du pays** : 30 s (et 15 s pour répondre, valeurs confirmées), mais la validation
  n'est plus perdue si le chrono expire pendant l'envoi : le choix du joueur reste prioritaire
  tant que personne n'a répondu ;
- **inscription** : l'adresse e-mail est marquée comme confirmée à la création du compte,
  donc plus besoin de recevoir l'e-mail de confirmation. Les comptes déjà créés mais non
  confirmés sont confirmés au passage.

Le résultat attendu :

```
choix_secondes = 30 | reponse_secondes = 15 | fonctions_submit_pick = 1
confirmation_auto = 1 | comptes_non_confirmes = 0
```

`11_salles_abandonnees.sql` ferme les parties laissées en cours (aucune activité depuis
5 minutes) et **rembourse les frais d'entrée**. Sans cela, une salle abandonnée bloque
définitivement la création de nouvelles salles. Le site appelle ensuite `cleanup_my_rooms()`
automatiquement à l'entrée de l'écran « Jouer ».

`12_round_secrets.sql` corrige l'erreur `column "secret" of relation "round_secrets" does
not exist` : la table venait d'une ancienne version et n'avait pas la bonne structure. Elle
est sauvegardée puis reconstruite. Le fichier affiche aussi un audit :

```
colonnes_round_secrets = round_id, secret, created_at | index_round_secrets = 2
colonnes_manquantes = []
```

`colonnes_manquantes = []` signifie que toutes les colonnes utilisées par le moteur existent.

`13_manches_uuid.sql` corrige l'erreur `column "round_id" is of type uuid but expression is of
type bigint` : dans cette base, `rounds.id` (et `answers.round_id`) venaient d'une ancienne
version en `bigint`. Le fichier sauvegarde `rounds / answers / round_secrets`, ferme les
parties en cours en **remboursant la mise**, puis reconstruit les trois tables en `uuid`
conformément au schéma officiel. S'il n'y a rien à corriger, il ne touche à rien.

Résultat attendu :

```
type_rounds_id = uuid | type_answers_round_id = uuid | type_secrets_round_id = uuid
manches = 0 | reponses = 0
```

### 2. Configurer le frontend

Renseigner `js/config.js` avec l'URL du projet et la clé **anon / publishable**
(Supabase → Project Settings → API).

### 3. Servir le site

Les modules ES ne fonctionnent pas en `file://` :

```powershell
python -m http.server 8080
```

Puis ouvrir `http://localhost:8080`. Sur GitHub Pages, le déploiement est automatique
après un `git push` sur `main` (compter une minute).

---

## Fonctionnalités

- Inscription / connexion par e-mail et mot de passe, pseudo unique modifiable.
- `2 000` crédits de bienvenue et bonus quotidien de `50` crédits (journée UTC).
- Salles privées avec code à 6 caractères ou lien d'invitation.
- Salle d'attente temps réel : prêt, hôte, expiration, transfert d'hôte.
- Choix d'un pays non encore joué, capitale secrète, puis réponse en **15 secondes**
  (30 secondes pour le choix du pays).
- Révélation anticipée dès que tous les répondants présents ont validé.
- Correction automatique : accents et ponctuation ignorés, variantes anglaises, petites
  fautes avec joker.
- Anti-collision entre capitales proches (Kingston ≠ Kingstown).
- Podium, départage par blocs d'au moins 5 pays (multiples du nombre de joueurs actifs),
  départage final par réponses parfaites puis temps de réponse.
- Récompenses `400 / 200 / 150` crédits, versées une seule fois.
- Missions quotidiennes (3 par jour : une facile, une moyenne, une difficile ou très
  difficile), paliers, trophées, statistiques et historique.
- Portefeuille, transactions et **boutique fermée par défaut**.
- Responsive mobile d'abord, navigation mobile, focus visible, `aria-live`.

### Comprendre les gains

- La **mise d'entrée** (`350` crédits) est débitée au lancement de la partie, pour tous les joueurs.
- La **récompense** (`400 / 200 / 150`) est créditée à la finalisation.
- Le solde augmente donc du **net** : `récompense − mise` (par exemple `400 − 350 = +50`).
- L'écran de fin affiche le bilan détaillé (mise, récompense, net) et le solde réel.
- Si l'affichage semble figé, le bouton « Actualiser mes gains » relance la finalisation
  (opération idempotente : un gain n'est jamais versé deux fois).

---

## Structure du dépôt

```
index.html                 Point d'entrée (CDN Supabase épinglé)
css/
  variables.css            Palette, typographie, espacements
  base.css                 Structure, en-tête, navigation, utilitaires
  components.css           Boutons, cartes, formulaires, badges, toasts…
  screens.css              Accueil, jeu, portefeuille, missions, podium…
js/
  config.js                URL Supabase + clé anon (à renseigner)
  supabaseClient.js        Client unique
  auth.js                  Session, inscription, connexion
  wallet.js                Portefeuille, bonus, statistiques
  missions.js              Missions du jour
  history.js               Historique des parties
  rooms.js                 RPC de salle + lecture de l'état
  gameConfig.js            Réglages publics pour l'affichage (RPC)
  sessionFlow.js           Reprise d'une invitation
  pending.js               Mémorisation du code d'invitation
  router.js                Routeur par hash
  app.js                   Bootstrap et routes
  ui/                      Écrans (shell, accueil, auth, compte, jeu…)
supabase/sql/              Migrations SQL numérotées (01 → 07)
```

---

## Sécurité en un coup d'œil

- Le navigateur ne fait que **lire** les tables autorisées et **appeler des RPC**.
- `round_secrets` et `game_config` sont illisibles par le client : la capitale secrète du
  proposant n'est jamais exposée à l'API.
- La table `countries` n'expose que `id, iso2, name_fr, name_en` : les capitales
  (`capital_fr`, `capital_en`) ne sont pas lisibles par un joueur.
- `rounds.correct_names` et `rounds.reveal_note` ne sont écrits qu'au moment de la
  révélation : rien à lire pendant la phase de réponses.
- La table `answers` n'est lisible qu'une fois la manche révélée (`status = 'revealed'`).
- Tous les mouvements de crédits passent par `wallet_apply` avec une clé d'idempotence
  (`user_id`, `type`, `ref`), donc aucun double versement.
- Les fonctions internes (`cc_grade`, `cc_finalize_round`, `cc_finalize_room`,
  `wallet_apply`…) ne sont pas exécutables par `authenticated`.

⚠️ **Boutique fermée** : `PURCHASES_ENABLED = false` dans `js/config.js`,
`payments_test_mode = 0` côté serveur et `create_purchase` révoquée pour `public`, `anon`
et `authenticated`. Aucun crédit ne peut donc être ajouté depuis le navigateur.

Pour rouvrir plus tard :

1. Brancher un webhook de paiement vérifié (Edge Function).
2. Redonner l'autorisation d'exécution, avec la signature exacte :
   ```sql
   grant execute on function create_purchase(smallint) to authenticated;
   ```
3. Passer `PURCHASES_ENABLED` à `true` dans `js/config.js`.

---

## Limites connues

- Pas de tournois, d'amis, de chat ni de classement mondial.
- Pas d'interface d'administration : les réglages se font dans `game_config` et les tables
  de référence.
- Le webhook de paiement réel n'est pas inclus.
- Aucun envoi d'e-mail personnalisé : Supabase Auth gère la confirmation d'adresse.
