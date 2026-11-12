/* =====================================================================
   Salle d'attente, jeu en temps réel et résultats.
   ===================================================================== */
import { supabase } from '../supabaseClient.js';
import { getUser } from '../auth.js';
import {
  syncServerClock, serverNow, getCountries, fetchRoomSnapshot,
  setReady, leaveRoom, pingRoom, startGame, submitPick, submitAnswer,
  advanceRoom, createRoom, saveSecret
} from '../rooms.js';
import { navigate } from '../router.js';
import { getGameConfig, DEFAULT_CONFIG } from '../gameConfig.js';
import {
  escapeHtml, formatCredits, formatDuration, friendlyError, toast,
  copyText, initials, adjustedTotal, phaseLabel, formatShortDate
} from '../utils.js';

function playerName(player) {
  return player?.profiles?.username || 'Joueur';
}

function scoreNumber(player) {
  return Number(player?.score || 0);
}

function fmtScore(value) {
  return Number(value || 0).toLocaleString('fr-FR', { maximumFractionDigits: 1 });
}

function normalizeText(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();
}

function stored(key) {
  try { return sessionStorage.getItem(key) || ''; } catch { return ''; }
}

function store(key, value) {
  try { sessionStorage.setItem(key, value); } catch { /* ignore */ }
}

function timerHtml(target) {
  return `<div class="timer js-timer" data-target="${escapeHtml(target)}" role="timer" aria-live="polite">--</div>`;
}

/* Causes renvoyées par submit_pick : message clair pour le joueur. */
const PICK_REASONS = {
  too_late: 'Le temps de choix est écoulé et un pays a déjà été tiré au hasard. Attends la révélation.',
  not_picking: 'La manche a déjà avancé : ton choix n’a pas été enregistré.',
  not_your_turn: 'Ce n’est pas ton tour de proposer un pays.',
  country_already_played: 'Ce pays a déjà été joué dans cette partie. Choisis-en un autre.',
  unknown_country: 'Ce pays est introuvable. Recharge la page.',
  room_not_found: 'Cette salle n’existe plus.',
  round_not_found: 'Cette manche n’existe plus. Recharge la page.',
  not_authenticated: 'Ta session a expiré. Reconnecte-toi.',
  invalid_capital: 'Saisis une vraie capitale (au moins une lettre).',
  capital_too_long: 'La capitale est limitée à 60 caractères.'
};

function scoreboardHtml(players, meId, { final = false } = {}) {
  const sorted = [...players].sort((a, b) => {
    if (a.is_forfeit !== b.is_forfeit) return a.is_forfeit ? 1 : -1;
    if (final && (a.final_rank || b.final_rank)) {
      return (a.final_rank || 99) - (b.final_rank || 99);
    }
    return scoreNumber(b) - scoreNumber(a);
  });

  let activeRank = 0;
  return sorted.map((player) => {
    let rankLabel = '—';
    if (!player.is_forfeit) {
      activeRank += 1;
      rankLabel = final && player.final_rank ? `#${player.final_rank}` : `#${activeRank}`;
    }
    return `
      <div class="score-row ${player.user_id === meId ? 'score-row--me' : ''}">
        <span class="score-row__rank">${rankLabel}</span>
        <span class="avatar ${player.is_forfeit ? '' : 'avatar--gold'}" aria-hidden="true">${escapeHtml(initials(playerName(player)))}</span>
        <span class="score-row__name">${escapeHtml(playerName(player))}${player.user_id === meId ? ' (vous)' : ''}</span>
        ${player.is_forfeit ? '<span class="badge badge--red">Forfait</span>' : ''}
        ${player.joker_used ? '<span class="badge" title="Joker orthographique utilisé">Joker</span>' : ''}
        <span class="score-row__score">${fmtScore(player.score)}</span>
      </div>`;
  }).join('');
}

/* =====================================================================
   Contrôleur temps réel
   ===================================================================== */
class PlayController {
  constructor(root, roomId, userId) {
    this.root = root;
    this.roomId = roomId;
    this.userId = userId;
    this.state = null;
    this.config = DEFAULT_CONFIG;
    this.countries = [];
    this.countryQuery = '';
    this.selectedCountryId = null;
    this.inFlight = false;
    this.refreshTimer = null;
    this.tickTimer = null;
    this.pingTimer = null;
    this.channel = null;
    this.lastAdvanceAt = 0;
    this.autoSubmittedRound = null;
    this.submitting = false;
    this.destroyed = false;
    this.finalizeRequested = false;
    this.celebrated = false;
  }

  async start() {
    this.config = await getGameConfig();
    await syncServerClock();
    try {
      this.countries = await getCountries();
    } catch {
      this.countries = [];
    }
    await this.refresh(true);
    this.subscribe();
    this.refreshTimer = window.setInterval(() => this.refresh(), 3000);
    this.tickTimer = window.setInterval(() => this.tick(), 250);
    this.pingTimer = window.setInterval(() => {
      pingRoom(this.roomId).catch(() => {});
    }, 10000);
    pingRoom(this.roomId).catch(() => {});
  }

  destroy() {
    this.destroyed = true;
    window.clearInterval(this.refreshTimer);
    window.clearInterval(this.tickTimer);
    window.clearInterval(this.pingTimer);
    if (this.channel) supabase.removeChannel(this.channel);
  }

  subscribe() {
    this.channel = supabase
      .channel(`room-${this.roomId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${this.roomId}` }, () => this.scheduleRefresh())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${this.roomId}` }, () => this.scheduleRefresh())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rounds', filter: `room_id=eq.${this.roomId}` }, () => this.scheduleRefresh())
      .subscribe();
  }

  scheduleRefresh() {
    if (this.refreshTimerHandle) return;
    this.refreshTimerHandle = window.setTimeout(() => {
      this.refreshTimerHandle = null;
      this.refresh();
    }, 150);
  }

  async refresh(force = false) {
    if (this.inFlight || this.destroyed) return;
    this.inFlight = true;
    try {
      const snapshot = await fetchRoomSnapshot(this.roomId);
      if (!snapshot) {
        this.renderMissing();
        return;
      }
      const signature = this.signatureOf(snapshot);
      // L'état est toujours rafraîchi (présence, horloges) ; le rendu n'est
      // refait que si quelque chose de visible a changé.
      this.state = snapshot;
      if (force || signature !== this.signature) {
        this.signature = signature;
        this.render();
      }
    } catch (error) {
      console.warn('Rafraîchissement de la salle impossible :', error?.message || error);
    } finally {
      this.inFlight = false;
    }
  }

  signatureOf(snapshot) {
    const { room, players, round, answers, progress } = snapshot;
    const playersSig = players
      .map((p) => [p.user_id, p.is_ready, p.is_forfeit, scoreNumber(p), p.final_rank, p.reward, p.seat, p.joker_used, playerName(p)].join(':'))
      .join('|');
    return [
      room.phase, room.current_round, room.total_rounds, room.tiebreak_blocks,
      room.host_id, room.finished_at, room.ended_by_forfeit, room.phase_ends_at,
      room.expires_at, room.target_rounds,
      round?.id, round?.status, round?.country_id, round?.auto_picked, round?.found,
      round?.correct_names, round?.reveal_note, round?.answer_ends_at, round?.pick_ends_at,
      answers.length, answers.map((a) => `${a.user_id}:${a.grade}:${a.points}:${a.joker_consumed}`).join(','),
      progress?.answered, progress?.total,
      this.countries.length
    ].join('~');
  }

  /* -------------------------------------------------------------------
     Horloge et avancement automatique
     ------------------------------------------------------------------- */
  tick() {
    document.querySelectorAll('.js-timer').forEach((el) => {
      const target = new Date(el.dataset.target).getTime();
      if (Number.isNaN(target)) return;
      const remaining = target - serverNow();
      el.textContent = formatDuration(remaining);
      el.classList.toggle('timer--warn', remaining > 0 && remaining <= 10000);
      el.classList.toggle('timer--danger', remaining <= 0);
    });

    const state = this.state;
    if (!state) return;
    const { room, round, progress } = state;

    let deadline = null;
    if (room.phase === 'waiting') deadline = room.expires_at;
    else if (room.phase === 'picking' && round) deadline = round.pick_ends_at;
    else if (room.phase === 'answering' && round) deadline = round.answer_ends_at;
    else if (room.phase === 'revealing') deadline = room.phase_ends_at;
    if (!deadline) return;

    const remaining = new Date(deadline).getTime() - serverNow();

    // Envoi automatique de la saisie en cours juste avant la fin du chrono.
    if (room.phase === 'answering' && round && remaining <= 350) {
      if (this.autoSubmittedRound !== round.id) {
        this.autoSubmittedRound = round.id;
        const input = this.root.querySelector('#answer-input');
        const text = (input?.value || stored(`answered:${round.id}`) || '').trim();
        if (text && !stored(`answered:${round.id}`)) {
          this.sendAnswer(text, { auto: true }).catch(() => {});
        }
      }
    }

    // Tout le monde a répondu : la révélation peut être demandée sans attendre le chrono.
    if (room.phase === 'answering' && progress
        && progress.answered >= progress.total
        && Date.now() - this.lastAdvanceAt > 1200) {
      this.lastAdvanceAt = Date.now();
      advanceRoom(this.roomId).then(() => this.refresh()).catch(() => {});
      return;
    }

    // Petit délai de grâce pendant le choix du pays : si le joueur clique juste
    // à la fin du chrono, son envoi arrive avant le tirage au hasard.
    const lateGrace = room.phase === 'picking' ? 2000 : 0;

    if (remaining <= -lateGrace && Date.now() - this.lastAdvanceAt > 1300) {
      this.lastAdvanceAt = Date.now();
      const jitter = Math.floor(Math.random() * 500);
      window.setTimeout(async () => {
        try {
          await advanceRoom(this.roomId);
          this.refresh();
        } catch (error) {
          console.warn('advance_room :', error?.message || error);
        }
      }, jitter);
    }
  }

  /* -------------------------------------------------------------------
     Rendu
     ------------------------------------------------------------------- */
  render() {
    const state = this.state;
    if (!state) return;
    const { room } = state;

    if (room.phase === 'cancelled') {
      this.root.innerHTML = this.cancelledHtml();
      this.bindCommon();
      return;
    }

    const focused = document.activeElement;
    const focusId = focused?.id;
    const selectionStart = focused?.selectionStart;
    const values = {
      'answer-input': this.root.querySelector('#answer-input')?.value,
      'secret-capital': this.root.querySelector('#secret-capital')?.value,
      'country-search': this.root.querySelector('#country-search')?.value,
      code: this.root.querySelector('#code')?.value
    };

    let body = '';
    if (room.phase === 'waiting') body = this.lobbyHtml();
    else if (room.phase === 'finished') body = this.finishedHtml();
    else body = this.gameHtml();

    this.root.innerHTML = `
      <div class="play-wrap">
        ${this.headerHtml()}
        ${body}
      </div>`;

    this.bindCommon();

    Object.entries(values).forEach(([id, value]) => {
      const el = this.root.querySelector(`#${id}`);
      if (el && value != null) el.value = value;
    });

    if (focusId) {
      const el = this.root.querySelector(`#${focusId}`);
      if (el) {
        el.focus();
        if (typeof selectionStart === 'number' && el.setSelectionRange) {
          try { el.setSelectionRange(selectionStart, selectionStart); } catch { /* ignore */ }
        }
      }
    }

    if (room.phase === 'waiting') this.bindLobby();
    else if (room.phase === 'picking') this.bindPicking();
    else if (room.phase === 'answering') this.bindAnswering();
    else if (room.phase === 'finished') this.bindFinished();
  }

  headerHtml() {
    const { room, players } = this.state;
    return `
      <div class="play-head">
        <div class="row">
          <a class="btn btn--ghost btn--sm" id="back-dashboard" href="#/tableau-de-bord">← Tableau de bord</a>
          <span class="badge">Salle <span class="mono">${escapeHtml(room.code)}</span></span>
          <span class="badge badge--teal">${escapeHtml(phaseLabel(room.phase))}</span>
        </div>
        <div class="row">
          <span class="small muted">${players.length} joueur(s)</span>
          ${room.phase === 'waiting' ? `<button class="btn btn--sm btn--ghost" id="copy-code" type="button">Copier le code</button>` : ''}
        </div>
      </div>`;
  }

  /* -------------------------------------------------------------------
     Salle d'attente
     ------------------------------------------------------------------- */
  lobbyHtml() {
    const { room, players } = this.state;
    const me = players.find((p) => p.user_id === this.userId);
    const isHost = room.host_id === this.userId;
    const allReady = players.length >= this.config.min_players && players.every((p) => p.is_ready);
    const adjusted = adjustedTotal(room.target_rounds, players.length);
    const perPlayer = players.length > 0 ? Math.round(adjusted / players.length) : adjusted;
    const invite = this.inviteLink();

    return `
      <div class="room-shell">
        <section class="card">
          <div class="card__title">
            <h2>Salle d’attente</h2>
            <span class="countdown-chip" aria-live="polite">Expire dans <span class="js-timer mono" data-target="${escapeHtml(room.expires_at)}">--</span></span>
          </div>

          <div class="center" style="padding:10px 0 18px">
            <div class="small muted">Code de la salle</div>
            <div class="room-code">${escapeHtml(room.code)}</div>
          </div>

          <div class="invite-box">
            <code>${escapeHtml(invite)}</code>
            <button class="btn btn--sm btn--teal" id="copy-invite" type="button">Copier le lien</button>
          </div>

          <div class="alert alert--info mt-4">
            <strong>${adjusted} pays</strong> prévus — ${perPlayer} proposition(s) par joueur.
            <span class="tiny">Le serveur ajuste ce nombre au lancement pour que tout le monde propose autant de fois.</span>
          </div>

          <h3 class="mt-6">Joueurs (${players.length}/${room.max_players})</h3>
          <div class="player-list">
            ${players.map((p) => {
              const isMe = p.user_id === this.userId;
              return `
                <div class="player-row ${isMe ? 'player-row--me' : ''}">
                  <span class="avatar" aria-hidden="true">${escapeHtml(initials(playerName(p)))}</span>
                  <span class="player-row__name">${escapeHtml(playerName(p))}${isMe ? ' (vous)' : ''}</span>
                  ${p.user_id === room.host_id ? '<span class="badge badge--gold">Hôte</span>' : ''}
                  <span class="player-row__meta">
                    ${p.is_ready
                      ? '<span class="badge badge--green">Prêt</span>'
                      : '<span class="badge">En attente</span>'}
                  </span>
                </div>`;
            }).join('')}
          </div>

          <div class="game-actions">
            <button class="btn btn--danger btn--sm" id="leave-room" type="button">Quitter la salle</button>
            <div class="row">
              ${!isHost ? `
                <button class="btn ${me?.is_ready ? 'btn--ghost' : 'btn--teal'}" id="ready-btn" type="button">
                  ${me?.is_ready ? 'Je ne suis plus prêt' : 'Je suis prêt'}
                </button>` : `<span class="badge badge--gold">Vous êtes l’hôte et déjà prêt</span>`}
              ${isHost ? `
                <button class="btn btn--gold" id="start-btn" type="button"
                        ${allReady ? '' : 'disabled'}
                        title="${allReady ? '' : `Il faut au moins ${this.config.min_players} joueurs, tous prêts`}">
                  Lancer la partie
                </button>` : ''}
            </div>
          </div>
          ${!allReady ? `<p class="small muted mt-2">${players.length < this.config.min_players ? `Il faut au moins ${this.config.min_players} joueurs.` : 'Tous les joueurs doivent être prêts.'}</p>` : ''}
        </section>

        <aside class="card card--flat">
          <div class="card__title"><h3>Avant de lancer</h3></div>
          <ul class="small muted" style="padding-left:18px;margin:0">
            <li>Frais d’entrée : <strong>${formatCredits(room.entry_fee)} crédits</strong> par joueur, débités une seule fois.</li>
            <li>Un joueur sans ${formatCredits(room.entry_fee)} crédits ne peut pas se déclarer prêt.</li>
            <li>La salle expire après ${this.config.lobby_minutes} minutes : rien n’est débité.</li>
            <li>Quitter avant le lancement est gratuit.</li>
            <li>Le lien d’invitation permet d’entrer directement.</li>
          </ul>
          <div class="divider"></div>
          <p class="small muted mt-0">
            Certaines capitales ont des notes culturelles à la révélation
            (ex. Abidjan est la capitale économique de la Côte d’Ivoire).
          </p>
        </aside>
      </div>`;
  }

  bindLobby() {
    this.root.querySelector('#copy-code')?.addEventListener('click', async () => {
      const ok = await copyText(this.state.room.code);
      toast(ok ? 'Code copié.' : 'Copie impossible sur ce navigateur.', ok ? 'success' : 'error');
    });

    this.root.querySelector('#copy-invite')?.addEventListener('click', async () => {
      const ok = await copyText(this.inviteLink());
      toast(ok ? 'Lien d’invitation copié.' : 'Copie impossible sur ce navigateur.', ok ? 'success' : 'error');
    });

    this.root.querySelector('#leave-room')?.addEventListener('click', async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      try {
        await leaveRoom(this.roomId);
        toast('Salle quittée.', 'success');
        navigate('/jouer');
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
      }
    });

    this.root.querySelector('#ready-btn')?.addEventListener('click', async (event) => {
      const me = this.state.players.find((p) => p.user_id === this.userId);
      const button = event.currentTarget;
      button.disabled = true;
      try {
        const result = await setReady(this.roomId, !me?.is_ready);
        if (result && result.ok === false && result.reason === 'insufficient_funds') {
          toast(`Solde insuffisant : ${formatCredits(result.balance)} crédits (${formatCredits(this.state.room.entry_fee)} requis).`, 'error');
        }
        await this.refresh(true);
      } catch (error) {
        toast(friendlyError(error), 'error');
      } finally {
        button.disabled = false;
      }
    });

    this.root.querySelector('#start-btn')?.addEventListener('click', async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      button.textContent = 'Lancement…';
      try {
        const result = await startGame(this.roomId);
        if (result && result.ok === false) {
          throw new Error(result.reason === 'expired' ? 'La salle a expiré.' : 'Lancement impossible.');
        }
        toast('La partie commence !', 'success');
        await this.refresh(true);
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
        button.textContent = 'Lancer la partie';
      }
    });
  }

  inviteLink() {
    const { room } = this.state;
    return `${window.location.origin}${window.location.pathname}?room=${encodeURIComponent(room.code)}`;
  }

  /* -------------------------------------------------------------------
     Partie en cours
     ------------------------------------------------------------------- */
  gameHtml() {
    const { room, players, round, progress } = this.state;
    const proposer = players.find((p) => p.user_id === round?.proposer_id);
    const me = players.find((p) => p.user_id === this.userId);
    const isProposer = round?.proposer_id === this.userId;
    const country = this.countries.find((c) => c.id === round?.country_id);

    let content = '';

    if (room.phase === 'picking') {
      content = isProposer ? this.pickingProposerHtml(round) : this.pickingWatcherHtml(round, proposer);
    } else if (room.phase === 'answering') {
      content = this.answeringHtml(round, proposer, country, me, progress);
    } else if (room.phase === 'revealing') {
      content = this.revealHtml(round, country);
    }

    return `
      <div class="room-shell">
        <section>
          ${room.tiebreak_blocks > 0 ? `
            <div class="tiebreak-banner">
              <span aria-hidden="true">⚖</span>
              Départage en cours — bloc supplémentaire ${room.tiebreak_blocks}/${this.config.tiebreak_max_blocks}.
              Les points se cumulent et les jokers restent acquis.
            </div>` : ''}
          <div class="round-card">
            <div class="round-card__top">
              <span class="round-card__phase">${escapeHtml(phaseLabel(room.phase))}</span>
              <span class="badge">Tour ${room.current_round} / ${room.total_rounds}</span>
            </div>
            ${content}
          </div>

          ${room.phase === 'revealing' ? this.answersHtml() : ''}
        </section>

        <aside class="stack">
          <div class="card card--flat">
            <div class="card__title"><h3>Classement</h3><span class="badge">${players.length}</span></div>
            <div class="scoreboard">${scoreboardHtml(players, this.userId)}</div>
          </div>
          <div class="card card--flat">
            <div class="row row--between">
              <span class="small muted">Proposant</span>
              <strong class="small">${escapeHtml(playerName(proposer))}</strong>
            </div>
            <div class="divider"></div>
            <button class="btn btn--danger btn--sm btn--block" id="leave-game" type="button">Quitter la partie</button>
          </div>
        </aside>
      </div>`;
  }

  pickingProposerHtml(round) {
    const filtered = this.filteredCountries();
    const selected = this.countries.find((c) => c.id === this.selectedCountryId);

    return `
      <div class="round-card__body">
        <div class="round-card__label">À vous de proposer un pays</div>
        <h2 class="country-name" style="font-size:clamp(1.6rem,4vw,2.3rem)">Choisissez un pays, gardez sa capitale secrète.</h2>
        <p class="round-card__hint">Les autres joueurs ne verront votre capitale qu’à la révélation (et seulement si personne ne trouve).</p>
        ${timerHtml(round.pick_ends_at)}
        <div class="timer-meta">Temps restant pour choisir le pays</div>
      </div>

      <form id="pick-form" class="stack" style="text-align:left">
        <div class="field">
          <label for="country-search">Rechercher un pays</label>
          <input class="input" id="country-search" type="search" autocomplete="off"
                 placeholder="Ex. Côte d’Ivoire, Japon, Brésil…" value="${escapeHtml(this.countryQuery)}">
        </div>

        <div class="row row--between small muted">
          <span>${filtered.length} pays affiché(s)</span>
          <span>${this.countries.length} pays au catalogue</span>
        </div>

        <div class="country-list" id="country-list" role="listbox" aria-label="Pays disponibles">
          ${this.countries.length === 0 ? `<p class="small muted" style="padding:8px">Liste des pays indisponible. Rechargez la page.</p>` : filtered.length === 0 ? `<p class="small muted" style="padding:8px">Aucun pays ne correspond.</p>` : filtered.map((c) => `
            <button type="button" role="option" aria-selected="${c.id === this.selectedCountryId}"
                    class="country-option ${c.id === this.selectedCountryId ? 'is-selected' : ''}"
                    data-country="${c.id}">
              ${escapeHtml(c.name_fr)} <span class="tiny muted">${escapeHtml(c.iso2)}</span>
            </button>`).join('')}
        </div>

        <div class="alert ${selected ? 'alert--success' : ''}" id="selected-country">
          ${selected ? `Pays choisi : <strong>${escapeHtml(selected.name_fr)}</strong>` : 'Aucun pays sélectionné.'}
        </div>

        <div class="field">
          <label for="secret-capital">Capitale de ce pays (secrète)</label>
          <input class="input" id="secret-capital" type="text" maxlength="60"
                 autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                 placeholder="Saisissez la capitale exacte" value="${escapeHtml(stored(`secret-draft:${round.id}`))}">
          <span class="field__hint">Aucune autocomplétion n’est proposée : elle révélerait la réponse.</span>
        </div>

        <div class="alert alert--error hidden" id="pick-error" role="alert"></div>

        <button class="btn btn--gold btn--lg btn--block" type="submit" id="pick-btn">Lancer le défi</button>
        <p class="small muted" style="margin:0">Une fois lancé, les autres joueurs ont ${this.config.answer_seconds} secondes pour trouver la capitale.</p>
      </form>`;
  }

  pickingWatcherHtml(round, proposer) {
    return `
      <div class="round-card__body">
        <div class="round-card__label">Au tour de</div>
        <h2 class="country-name">${escapeHtml(playerName(proposer))}</h2>
        <p class="round-card__hint">Vous verrez le pays dès que le défi sera lancé.</p>
        ${timerHtml(round.pick_ends_at)}
        <div class="timer-meta">Temps restant pour proposer un pays</div>
      </div>
      <div class="alert alert--info center">
        Le proposant saisit sa capitale en secret. Si le délai expire, un pays sera tiré au hasard.
      </div>`;
  }

  answeringHtml(round, proposer, country, me, progress) {
    const isProposer = round.proposer_id === this.userId;
    const answeredText = stored(`answered:${round.id}`);
    const displayCountry = country?.name_fr || 'le pays';

    return `
      <div class="round-card__body">
        <div class="round-card__label">Proposé par ${escapeHtml(playerName(proposer))}</div>
        <h2 class="country-name">${escapeHtml(displayCountry)}</h2>
        <p class="round-card__hint">${isProposer ? 'Vous avez proposé ce pays. Attendez les réponses.' : 'Quelle est la capitale de ce pays ?'}</p>
        ${timerHtml(round.answer_ends_at)}
        <div class="timer-meta">
          ${round.auto_picked ? 'Pays tiré automatiquement (proposant absent).' : ''}
          <span>${progress?.answered ?? 0} / ${progress?.total ?? 0} réponse(s) envoyée(s)</span>
        </div>

        ${isProposer ? `
          <div class="alert alert--gold mt-4">
            Votre réponse secrète est enregistrée. Elle ne sera notée que si personne ne trouve.
          </div>` : answeredText ? `
          <div class="alert alert--success mt-4">
            Réponse validée : <strong>${escapeHtml(answeredText)}</strong>.<br>
            <span class="small">Elle est verrouillée : aucune modification possible.</span>
          </div>` : `
          <form class="answer-form" id="answer-form">
            <input class="input" id="answer-input" type="text" maxlength="60"
                   autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                   placeholder="Votre réponse" aria-label="Votre réponse" required>
            <button class="btn btn--gold" type="submit" id="answer-btn">Valider</button>
          </form>
          <p class="small muted mt-2">Accents, majuscules et tirets sont ignorés. Une petite faute peut être tolérée une fois grâce au joker.</p>`}
      </div>`;
  }

  revealHtml(round, country) {
    const { players } = this.state;
    const proposer = players.find((p) => p.user_id === round.proposer_id);
    const note = round.reveal_note;

    return `
      <div class="round-card__body" style="padding-bottom:10px">
        <div class="round-card__label">Réponse attendue</div>
        <div class="reveal-answer">
          <div class="reveal-answer__label">Capitale de ${escapeHtml(country?.name_fr || 'ce pays')}</div>
          <div class="reveal-answer__value">${escapeHtml(round.correct_names || '—')}</div>
          ${note ? `<div class="reveal-answer__note">${escapeHtml(note)}</div>` : ''}
        </div>

        <div class="alert ${round.found ? 'alert--success' : 'alert--gold'} mt-4">
          ${round.found
            ? '<strong>Bonne réponse trouvée.</strong> Les joueurs corrects marquent leurs points ; le proposant marque 0.'
            : `<strong>Personne n’a trouvé.</strong> ${round.auto_picked ? 'Le proposant n’a pas joué : il marque 0.' : 'La réponse secrète du proposant est maintenant notée.'}`}
        </div>

        <div class="timer-meta mt-4">
          Prochain tour dans
          <span class="js-timer mono" data-target="${escapeHtml(this.state.room.phase_ends_at || '')}">--</span> s
        </div>
        <p class="tiny muted">Proposant : ${escapeHtml(playerName(proposer))}</p>
      </div>`;
  }

  answersHtml() {
    const { answers } = this.state;
    if (!answers || answers.length === 0) {
      return `<div class="card mt-4"><div class="empty">Aucune réponse enregistrée pour ce tour.</div></div>`;
    }

    return `
      <div class="card mt-4">
        <div class="card__title"><h3>Réponses de la manche</h3><span class="badge">${answers.length}</span></div>
        <div class="answer-list">
          ${answers.map((a) => {
            const cls = a.grade === 'perfect' ? 'answer-row--correct'
              : a.grade === 'typo' ? 'answer-row--typo'
              : 'answer-row--wrong';
            const label = a.grade === 'perfect' ? 'Parfaite'
              : a.grade === 'typo' ? 'Petite faute'
              : a.grade === 'wrong' ? 'Incorrecte' : '—';
            return `
              <div class="answer-row ${cls}">
                <span class="avatar" aria-hidden="true">${escapeHtml(initials(playerName(a)))}</span>
                <span>
                  <span class="answer-row__text">${escapeHtml(a.text)}</span><br>
                  <span class="tiny muted">${escapeHtml(playerName(a))} · ${label}</span>
                </span>
                <span class="answer-row__meta">
                  ${a.joker_consumed ? '<span class="badge badge--gold">Joker</span>' : ''}
                  <span class="points">+${fmtScore(a.points)}</span>
                </span>
              </div>`;
          }).join('')}
        </div>
      </div>`;
  }

  filteredCountries() {
    const query = normalizeText(this.countryQuery);
    // Aucune troncature : les 195 pays du catalogue restent accessibles.
    if (!query) return this.countries;
    return this.countries.filter(
      (c) => normalizeText(c.name_fr).includes(query) || normalizeText(c.name_en).includes(query)
    );
  }

  bindPicking() {
    const search = this.root.querySelector('#country-search');
    const list = this.root.querySelector('#country-list');
    const selectedBox = this.root.querySelector('#selected-country');
    const form = this.root.querySelector('#pick-form');
    const secret = this.root.querySelector('#secret-capital');

    const paintList = () => {
      if (!list) return;
      const items = this.filteredCountries();
      list.innerHTML = items.length === 0
        ? `<p class="small muted" style="padding:8px">Aucun pays ne correspond.</p>`
        : items.map((c) => `
            <button type="button" role="option" aria-selected="${c.id === this.selectedCountryId}"
                    class="country-option ${c.id === this.selectedCountryId ? 'is-selected' : ''}"
                    data-country="${c.id}">
              ${escapeHtml(c.name_fr)} <span class="tiny muted">${escapeHtml(c.iso2)}</span>
            </button>`).join('');
    };

    search?.addEventListener('input', () => {
      this.countryQuery = search.value;
      paintList();
    });

    list?.addEventListener('click', (event) => {
      const button = event.target.closest('.country-option');
      if (!button) return;
      this.selectedCountryId = Number(button.dataset.country);
      const chosen = this.countries.find((c) => c.id === this.selectedCountryId);
      list.querySelectorAll('.country-option').forEach((node) => {
        const isSelected = Number(node.dataset.country) === this.selectedCountryId;
        node.classList.toggle('is-selected', isSelected);
        node.setAttribute('aria-selected', String(isSelected));
      });
      if (selectedBox) {
        selectedBox.className = 'alert alert--success';
        selectedBox.innerHTML = `Pays choisi : <strong>${escapeHtml(chosen?.name_fr || '')}</strong>`;
      }
    });

    secret?.addEventListener('input', () => {
      const round = this.state.round;
      if (round) store(`secret-draft:${round.id}`, secret.value);
    });

    const button = this.root.querySelector('#pick-btn');
    const errorBox = this.root.querySelector('#pick-error');
    let busy = false;

    const showError = (message, detail) => {
      const text = detail ? `${message} (détail : ${detail})` : message;
      if (errorBox) {
        errorBox.textContent = text;
        errorBox.classList.remove('hidden');
      }
      toast(message, 'error');
    };

    const submitPickNow = async () => {
      if (busy) return;
      const capital = secret?.value.trim() || '';
      const countryId = this.selectedCountryId;

      if (errorBox) {
        errorBox.classList.add('hidden');
        errorBox.textContent = '';
      }

      if (!countryId) { showError('Choisissez d’abord un pays.'); return; }
      if (!capital) { showError('Saisissez la capitale secrète.'); secret?.focus(); return; }
      if (capital.length > 60) { showError('La capitale est limitée à 60 caractères.'); return; }

      busy = true;
      if (button) {
        button.disabled = true;
        button.textContent = 'Envoi…';
      }
      const release = () => {
        busy = false;
        if (button) {
          button.disabled = false;
          button.textContent = 'Lancer le défi';
        }
      };

      try {
        const result = await submitPick(this.roomId, countryId, capital);
        if (result && result.ok === false) {
          showError(
            PICK_REASONS[result.reason] || 'Envoi impossible.',
            result.reason || 'inconnu'
          );
          release();
          // La manche a changé d'état : on resynchronise l'écran.
          if (['too_late', 'not_picking', 'round_not_found', 'room_not_found'].includes(result.reason)) {
            await this.refresh(true);
          }
          return;
        }
        saveSecret(this.state.round.id, capital);
        this.selectedCountryId = null;
        toast('Défi lancé !', 'success');
        await this.refresh(true);
      } catch (error) {
        showError(friendlyError(error));
        release();
      }
    };

    // Clic direct sur le bouton : indépendant de la soumission du formulaire.
    button?.addEventListener('click', (event) => {
      event.preventDefault();
      submitPickNow();
    });

    // Touche Entrée dans un champ du formulaire.
    form?.addEventListener('submit', (event) => {
      event.preventDefault();
      submitPickNow();
    });

  }

  bindAnswering() {
    const form = this.root.querySelector('#answer-form');
    if (!form) {
      // Proposant ou réponse déjà validée : rien à lier.
      return;
    }

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const input = this.root.querySelector('#answer-input');
      const text = input?.value.trim() || '';
      if (!text) { toast('Saisissez une réponse.', 'error'); input?.focus(); return; }
      const button = this.root.querySelector('#answer-btn');
      button.disabled = true;
      button.textContent = 'Envoi…';
      try {
        await this.sendAnswer(text);
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
        button.textContent = 'Valider';
      }
    });

    const input = this.root.querySelector('#answer-input');
    if (input) input.focus();
  }

  async sendAnswer(text, { auto = false } = {}) {
    if (this.submitting) return;
    const round = this.state?.round;
    if (!round) return;
    this.submitting = true;
    try {
      const result = await submitAnswer(this.roomId, text);
      if (result && result.ok === false) {
        if (result.reason === 'already_answered') {
          store(`answered:${round.id}`, text);
        } else if (result.reason === 'too_late') {
          toast('Trop tard : la réponse n’a pas été prise en compte.', 'error');
        }
      } else {
        store(`answered:${round.id}`, text);
        toast(auto ? 'Réponse envoyée automatiquement.' : 'Réponse validée et verrouillée.', 'success');
      }
      await this.refresh(true);
    } finally {
      this.submitting = false;
    }
  }

  bindCommon() {
    this.root.querySelector('#back-dashboard')?.addEventListener('click', (event) => {
      const phase = this.state?.room?.phase;
      if (!['picking', 'answering', 'revealing'].includes(phase)) return;
      const confirmed = window.confirm(
        'Vous restez inscrit dans cette partie : sans revenir avant la fin du délai, vous risquez un tour manqué puis un forfait. Continuer ?'
      );
      if (!confirmed) event.preventDefault();
    });

    this.root.querySelector('#leave-game')?.addEventListener('click', async () => {
      const confirmed = window.confirm(
        'Quitter la partie maintenant vous met en forfait : vous ne pourrez plus marquer de points ni recevoir de récompense. Continuer ?'
      );
      if (!confirmed) return;
      try {
        await leaveRoom(this.roomId);
        toast('Vous avez quitté la partie.', 'info');
        navigate('/tableau-de-bord');
      } catch (error) {
        toast(friendlyError(error), 'error');
      }
    });
  }

  /* -------------------------------------------------------------------
     Résultats
     ------------------------------------------------------------------- */
  finishedHtml() {
    const { room, players } = this.state;
    const me = players.find((p) => p.user_id === this.userId);
    const ranked = players
      .filter((p) => p.final_rank && !p.is_forfeit)
      .sort((a, b) => a.final_rank - b.final_rank);
    const medals = { 1: '🏆', 2: '⭐', 3: '🥉' };
    const medalNames = { 1: 'Trophée', 2: 'Étoile', 3: 'Médaille' };
    const entry = Number(room.entry_fee || this.config.entry_fee || 0);
    const reward = Number(me?.reward || 0);
    const net = reward - entry;
    const champion = Boolean(me && !me.is_forfeit && me.final_rank === 1);

    return `
      ${champion ? `
        <div class="champion-banner">
          <span class="champion-banner__icon" aria-hidden="true">🏆</span>
          <span>Victoire ! Vous remportez le trophée de cette partie.</span>
        </div>` : ''}

      <div class="tiebreak-banner" style="border-color:rgba(242,184,75,.4);background:var(--gold-soft);color:#ffe4ac">
        <span aria-hidden="true">✦</span> Partie terminée — ${room.total_rounds} tours joués.
      </div>

      ${room.ended_by_forfeit ? `
        <div class="alert alert--gold" style="margin-bottom:16px">
          Cette partie s’est terminée par forfait. Elle ne compte pas pour les missions,
          les paliers ni les statistiques (anti-abus), mais les récompenses de crédits restent attribuées.
        </div>` : ''}

      <section class="card">
        <div class="card__title">
          <h2>Podium</h2>
          <span class="badge badge--gold">${ranked.length} classé(s)</span>
        </div>

        ${ranked.length === 0 ? `<div class="empty">Aucun joueur classé.</div>` : `
          <div class="podium">
            ${ranked.slice(0, 3).map((p) => `
              <div class="podium__place podium__place--${p.final_rank}">
                <div class="podium__medal" aria-hidden="true">${medals[p.final_rank] || '•'}</div>
                <div class="tiny muted">${medalNames[p.final_rank] || ''}</div>
                <div class="podium__name">${escapeHtml(playerName(p))}${p.user_id === this.userId ? ' (vous)' : ''}</div>
                <div class="podium__score">${fmtScore(p.score)} pt</div>
                <div class="podium__reward">${p.reward ? `+${formatCredits(p.reward)} crédits` : 'Aucune récompense'}</div>
              </div>`).join('')}
          </div>`}

        ${me ? `
          <div class="alert ${me.is_forfeit ? 'alert--gold' : 'alert--success'}">
            ${me.is_forfeit
              ? 'Vous êtes en forfait : vous restez visible au classement mais êtes exclu du podium et des récompenses.'
              : me.final_rank
                ? `Votre place : <strong>#${me.final_rank}</strong> · ${fmtScore(me.score)} point(s)`
                : 'Partie terminée.'}
          </div>

          <div class="card card--flat mt-6" id="my-rewards">
            <div class="card__title">
              <h3>Votre bilan</h3>
              <span class="badge badge--gold" id="my-balance-badge">Solde : …</span>
            </div>
            <div class="credit-receipt">
              <div class="credit-receipt__row">
                <span>Mise d’entrée (débitée au lancement)</span>
                <strong>-${formatCredits(entry)} crédits</strong>
              </div>
              <div class="credit-receipt__row">
                <span>Récompense de cette partie</span>
                <strong class="${reward > 0 ? 'text-green' : 'text-red'}">${reward > 0 ? `+${formatCredits(reward)}` : '+0'} crédits</strong>
              </div>
              <div class="credit-receipt__row credit-receipt__row--total">
                <span>Gain net sur la partie</span>
                <strong class="${net >= 0 ? 'text-green' : 'text-red'}">${net >= 0 ? '+' : ''}${formatCredits(net)} crédits</strong>
              </div>
            </div>
            <p class="small muted mt-2">
              Le portefeuille reçoit la récompense à la finalisation serveur, après la mise déjà débitée.
              C’est pourquoi le solde augmente du gain net, et non du montant brut affiché sur le podium.
            </p>
            <button class="btn btn--ghost btn--sm" id="refresh-gains" type="button">Actualiser mes gains</button>
            <div id="my-trophies" class="mt-4"><p class="small muted">Chargement de vos trophées…</p></div>
          </div>` : ''}

        <h3 class="mt-6">Classement complet</h3>
        <div class="scoreboard">${scoreboardHtml(players, this.userId, { final: true })}</div>

        <div class="game-actions">
          <a class="btn btn--ghost" href="#/tableau-de-bord">Tableau de bord</a>
          <button class="btn btn--gold" id="replay-btn" type="button">Rejouer (nouvelle salle)</button>
        </div>
      </section>`;
  }

  bindFinished() {
    this.root.querySelector('#replay-btn')?.addEventListener('click', async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      button.textContent = 'Création…';
      try {
        const result = await createRoom(this.state.room.target_rounds);
        if (!result?.ok) throw new Error(result?.reason || 'Création impossible');
        toast(`Nouvelle salle ${result.code} créée.`, 'success');
        navigate(`/partie/${result.id}`);
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
        button.textContent = 'Rejouer (nouvelle salle)';
      }
    });

    // Filet de sécurité : la récompense n'est versée qu'à la finalisation serveur.
    // Si le dernier joueur a fermé son onglet, on redemande la finalisation (idempotente).
    if (!this.finalizeRequested) {
      this.finalizeRequested = true;
      advanceRoom(this.roomId).then(() => this.refresh(true)).catch(() => {});
    }

    this.root.querySelector('#refresh-gains')?.addEventListener('click', async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      button.textContent = 'Actualisation…';
      try {
        await advanceRoom(this.roomId);
        await this.refresh(true);
        toast('Gains et solde actualisés.', 'success');
      } catch (error) {
        toast(friendlyError(error), 'error');
        button.disabled = false;
        button.textContent = 'Actualiser mes gains';
      }
    });

    this.loadRewardsPanel();

    if (!this.celebrated) {
      this.celebrated = true;
      const me = this.state.players.find((p) => p.user_id === this.userId);
      if (me && !me.is_forfeit && me.final_rank === 1) this.celebrate();
    }
  }

  /* Solde réel et trophées : chargés après le rendu pour ne pas bloquer le podium. */
  async loadRewardsPanel() {
    const panel = this.root.querySelector('#my-rewards');
    if (!panel || this.destroyed) return;

    try {
      const { data } = await supabase
        .from('wallets')
        .select('balance')
        .eq('user_id', this.userId)
        .maybeSingle();
      const badge = panel.querySelector('#my-balance-badge');
      if (badge && data) badge.textContent = `Solde : ${formatCredits(data.balance)} crédits`;
    } catch { /* solde indisponible : le bilan reste lisible */ }

    const box = panel.querySelector('#my-trophies');
    if (!box) return;

    try {
      const { data } = await supabase
        .from('user_milestones')
        .select('code, achieved_at, milestones(title)')
        .eq('user_id', this.userId)
        .order('achieved_at', { ascending: false });

      if (!Array.isArray(data) || data.length === 0) {
        box.innerHTML = `<p class="small muted">Aucun trophée pour l’instant. Terminez une partie normale
          (sans forfait ni abandon) pour débloquer « Première partie jouée ».</p>`;
        return;
      }

      box.innerHTML = `
        <div class="small muted">Trophées débloqués</div>
        <div class="trophy-grid mt-2">
          ${data.map((m) => `
            <div class="trophy trophy--unlocked">
              <div class="trophy__icon" aria-hidden="true">🏆</div>
              <div class="trophy__title">${escapeHtml(m.milestones?.title || m.code)}</div>
              <div class="trophy__meta">${formatShortDate(m.achieved_at)}</div>
            </div>`).join('')}
        </div>`;
    } catch {
      box.innerHTML = `<p class="small muted">Trophées indisponibles pour le moment.</p>`;
    }
  }

  celebrate() {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const host = document.createElement('div');
    host.className = 'confetti';
    host.setAttribute('aria-hidden', 'true');
    const colors = ['#FFC61A', '#2438E0', '#5B3FD0', '#0B7F57', '#FFFFFF'];
    for (let i = 0; i < 70; i += 1) {
      const bit = document.createElement('span');
      bit.style.left = `${Math.random() * 100}%`;
      bit.style.background = colors[i % colors.length];
      bit.style.animationDelay = `${Math.random() * 0.8}s`;
      bit.style.animationDuration = `${2.2 + Math.random() * 1.8}s`;
      bit.style.setProperty('--dx', `${(Math.random() - 0.5) * 140}px`);
      host.appendChild(bit);
    }
    document.body.appendChild(host);
    window.setTimeout(() => host.remove(), 5200);
  }

  /* -------------------------------------------------------------------
     Salle annulée / introuvable
     ------------------------------------------------------------------- */
  cancelledHtml() {
    const { room } = this.state;
    const reasons = {
      expired: `La salle d’attente a expiré au bout de ${this.config.lobby_minutes} minutes.`,
      empty: 'Tous les joueurs ont quitté la salle.',
      host: 'L’hôte a fermé la salle.'
    };
    return `
      <div class="play-wrap">
        <div class="card">
          <div class="empty">
            <div class="empty__icon">⌛</div>
            <h2>Salle annulée</h2>
            <p>${escapeHtml(reasons[room.cancel_reason] || 'Cette salle n’est plus active.')}</p>
            <p class="small muted">Aucun crédit n’a été débité.</p>
            <a class="btn btn--gold" href="#/jouer">Créer une nouvelle salle</a>
          </div>
        </div>
      </div>`;
  }

  renderMissing() {
    if (this.destroyed) return;
    this.root.innerHTML = `
      <div class="container-mid">
        <div class="card">
          <div class="empty">
            <div class="empty__icon">🔒</div>
            <h2>Salle inaccessible</h2>
            <p>Elle n’existe pas, ou vous n’en êtes pas membre.</p>
            <a class="btn btn--gold" href="#/jouer">Retour à « Jouer »</a>
          </div>
        </div>
      </div>`;
  }
}

/* =====================================================================
   Entrée du routeur
   ===================================================================== */
export async function renderRoom(root, { id }) {
  const user = await getUser();
  if (!user) {
    navigate('/connexion');
    return undefined;
  }

  root.innerHTML = `<div class="loading-block"><div class="spinner" role="status"></div>Connexion à la salle…</div>`;

  const controller = new PlayController(root, id, user.id);
  await controller.start();
  return () => controller.destroy();
}
