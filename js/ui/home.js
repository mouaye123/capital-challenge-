/* =====================================================================
   Écran d'accueil.
   ===================================================================== */
import { getUser } from '../auth.js';
import { getGameConfig } from '../gameConfig.js';
import { formatCredits } from '../utils.js';

export async function renderHome(root) {
  const [user, config] = await Promise.all([getUser(), getGameConfig()]);

  root.innerHTML = `
    <section class="hero">
      <div>
        <span class="hero__eyebrow">Quiz multijoueur · temps réel</span>
        <h1 class="hero__title">Les capitales du monde,<br><em>un duel à plusieurs.</em></h1>
        <p class="hero__lead">
          Créez une salle privée, invitez vos amis et affrontez-vous sur les capitales
          des 195 pays. Chaque joueur propose un pays, garde sa capitale secrète,
          puis tout le monde répond en ${config.answer_seconds} secondes.
        </p>
        <div class="hero__actions">
          ${user
            ? `<a class="btn btn--gold btn--lg" href="#/jouer">Créer une salle</a>
               <a class="btn btn--ghost btn--lg" href="#/tableau-de-bord">Mon tableau de bord</a>`
            : `<a class="btn btn--gold btn--lg" href="#/inscription">Créer mon compte</a>
               <a class="btn btn--ghost btn--lg" href="#/connexion">J’ai déjà un compte</a>`}
        </div>
        <div class="hero__facts">
          <div class="hero__fact"><strong>195</strong><span>pays couverts</span></div>
          <div class="hero__fact"><strong>${config.min_players}–${config.max_players}</strong><span>joueurs par salle</span></div>
          <div class="hero__fact"><strong>${formatCredits(config.welcome_bonus)}</strong><span>crédits offerts</span></div>
        </div>
      </div>

      <div class="globe-card" aria-hidden="true">
        <span class="globe-card__orbit"></span>
        <span class="globe-card__orbit globe-card__orbit--2"></span>
        <div class="globe-card__center">
          <span class="pin">◉</span>
          <strong>Yamoussoukro</strong>
          <span>Côte d’Ivoire · capitale officielle</span>
        </div>
      </div>
    </section>

    <section class="section" aria-labelledby="how-title">
      <div class="section__head">
        <h2 id="how-title">Comment se déroule une partie ?</h2>
        <p>Six étapes, entièrement arbitrées par le serveur. Personne ne peut modifier un score ni une réponse depuis son navigateur.</p>
      </div>
      <div class="grid grid--3">
        <article class="feature-card">
          <div class="feature-card__icon">①</div>
          <h3>Créez ou rejoignez une salle</h3>
          <p>Un code à 6 caractères ou un lien d’invitation. De ${config.min_players} à ${config.max_players} joueurs, 15 à 55 pays.</p>
        </article>
        <article class="feature-card">
          <div class="feature-card__icon">②</div>
          <h3>Proposez un pays</h3>
          <p>Chacun son tour. Le proposant saisit la capitale en secret : impossible de la changer après coup.</p>
        </article>
        <article class="feature-card">
          <div class="feature-card__icon">③</div>
          <h3>Répondez en ${config.answer_seconds} s</h3>
          <p>La correction reconnaît les variantes et les petites fautes. Un joker orthographique par session.</p>
        </article>
        <article class="feature-card">
          <div class="feature-card__icon">④</div>
          <h3>Révélation immédiate</h3>
          <p>La bonne capitale, la note culturelle, les points de chacun et le joker consommé.</p>
        </article>
        <article class="feature-card">
          <div class="feature-card__icon">⑤</div>
          <h3>Départage équitable</h3>
          <p>Une égalité sur le podium ajoute un bloc d’au moins ${config.tiebreak_min_block} pays, sans nouveaux frais.</p>
        </article>
        <article class="feature-card">
          <div class="feature-card__icon">⑥</div>
          <h3>Podium et récompenses</h3>
          <p>${formatCredits(config.reward_1)}, ${formatCredits(config.reward_2)} et ${formatCredits(config.reward_3)} crédits. Missions quotidiennes et paliers pour rejouer.</p>
        </article>
      </div>
    </section>

    <section class="section">
      <div class="card card--teal">
        <div class="row row--between">
          <div>
            <h2 class="mt-0">Un compte, ${formatCredits(config.welcome_bonus)} crédits offerts</h2>
            <p class="muted mt-0">Les crédits sont virtuels : non retirables, non convertibles en argent réel.</p>
          </div>
          ${user
            ? `<a class="btn btn--teal" href="#/portefeuille">Voir mon portefeuille</a>`
            : `<a class="btn btn--teal" href="#/inscription">Commencer gratuitement</a>`}
        </div>
      </div>
    </section>
  `;
}
