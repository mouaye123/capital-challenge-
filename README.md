# Capital Challenge

Quiz multijoueur en temps réel sur les capitales du monde, de A à Z.

- **Frontend** : HTML, CSS et JavaScript natifs (modules ES), sans framework ni étape de build.
- **Backend** : Supabase uniquement — Auth, PostgreSQL, Realtime et fonctions SQL `SECURITY DEFINER`.
- **Hébergement** : compatible GitHub Pages (routage par hash, aucun serveur à maintenir).
- **Périmètre v1** : 195 pays (193 membres de l'ONU + Vatican + Palestine), 2 à 9 joueurs par salle, 15 à 55 pays par session, joker orthographique, missions quotidiennes, portefeuille virtuel et achats en mode test.

> Les crédits sont **virtuels** : non retirables, non convertibles en argent réel, non transférables.

---

## Démarrage rapide

1. Créer un projet Supabase.
2. Exécuter les fichiers SQL **dans cet ordre** dans le SQL Editor :
   1. `supabase/sql/01_schema.sql`
   2. `supabase/sql/02_seed_pays.sql`
   3. `supabase/sql/03_salles.sql`
   4. `supabase/sql/04_moteur.sql`
   5. `supabase/sql/05_missions.sql`
   6. `supabase/sql/06_achats.sql`
   7. `supabase/sql/07_correctif.sql` (missions, chrono 15 s, achats fermés)
3. Renseigner `js/config.js` avec l'URL du projet et la clé **anon / publishable**.
4. Servir le dossier en HTTP (les modules ES ne fonctionnent pas en `file://`) :
   ```powershell
   python -m http.server 8080
   ```
   Puis ouvrir `http://localhost:8080`.
5. Vérifier les données et la sécurité avec `tests/seed_check.sql`, `tests/grade_tests.sql` et `tests/security_tests.sql`.

La procédure complète (Auth, GitHub Pages, Realtime, achats) est dans [`docs/DEPLOIEMENT.md`](docs/DEPLOIEMENT.md).

---

## Fonctionnalités

- Inscription / connexion par e-mail et mot de passe, pseudo unique.
- `2 000` crédits de bienvenue et bonus quotidien de `50` crédits (journée UTC).
- Salles privées avec code à 6 caractères ou lien d'invitation.
- Salle d'attente temps réel : prêt, hôte, expiration, transfert d'hôte.
- Choix d'un pays non encore joué, capitale secrète, puis réponse en 15 secondes.
- Révélation anticipée dès que tous les répondants présents ont validé.
- Correction automatique : accents et ponctuation ignorés, variantes anglaises, petites fautes avec joker.
- Anti-collision entre capitales proches (Kingston ≠ Kingstown).
- Podium, départage par blocs d'au moins 5 pays (multiples du nombre de joueurs actifs), départage final par réponses parfaites puis temps de réponse.
- Récompenses `400 / 200 / 150` crédits, versées une seule fois.
- Missions quotidiennes, paliers, statistiques et historique.
- Portefeuille, transactions et **boutique fermée par défaut** (aucun achat possible tant que le paiement n'est pas vérifié).
- Responsive mobile d'abord, navigation mobile, focus visible, `aria-live`, contrastes soignés.

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
supabase/sql/              Migrations SQL numérotées
tests/                     Contrôles SQL (données, correction, sécurité)
docs/                      Décisions, design, déploiement, tests, capitales
```

---

## Documentation

- [`docs/DECISIONS.md`](docs/DECISIONS.md) — arbitrages et interprétations du cahier des charges.
- [`docs/DESIGN.md`](docs/DESIGN.md) — direction artistique et design system.
- [`docs/CAPITALES_A_VALIDER.md`](docs/CAPITALES_A_VALIDER.md) — cas politiques et capitales multiples à valider.
- [`docs/DEPLOIEMENT.md`](docs/DEPLOIEMENT.md) — installation Supabase, Auth, GitHub Pages, achats.
- [`docs/TESTS_MANUELS.md`](docs/TESTS_MANUELS.md) — scénarios de recette et de sécurité.

---

## Sécurité en un coup d'œil

- Le navigateur ne fait que **lire** les tables autorisées et **appeler des RPC**.
- `capitals`, `capital_aliases`, `round_secrets` et `game_config` sont illisibles par le client.
- Les réponses (`answers`) ne sont lisibles qu'après la révélation.
- Tous les mouvements de crédits passent par `wallet_apply` avec une clé d'idempotence.
- Les fonctions internes (`grade_answer`, `finalize_room`, `wallet_apply`…) ne sont pas exécutables par `authenticated`.
- `credit_purchase` est réservée à `service_role` pour le webhook de paiement.

⚠️ **Boutique fermée** : par défaut (`PURCHASES_ENABLED = false` dans `js/config.js` et
`payments_test_mode = 0` côté serveur), aucun achat ne peut être crédité. Pour rouvrir la
boutique, il faudra un webhook de paiement vérifié, réactiver l'interrupteur frontend et
redonner l'autorisation d'exécuter `create_purchase` (voir `supabase/sql/07_correctif.sql`).

---

## Limites connues de la v1

- Pas de tournois, d'amis, de chat ni de classement mondial (hors périmètre).
- Pas d'interface d'administration : les réglages se font dans `game_config` et les tables de référence.
- Le webhook de paiement réel n'est pas inclus ; seule la fonction SQL `credit_purchase` est prête.
- Les Edge Functions ne sont pas utilisées, sauf si vous ajoutez plus tard le webhook de paiement.
- Aucun envoi d'e-mail personnalisé : Supabase Auth gère la confirmation d'adresse.
