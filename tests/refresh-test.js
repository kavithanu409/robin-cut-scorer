// Refresh regression test: a reload must reopen the same page, never flash the home page,
// and a scorer on #score= must land back on the scoring pad.
// Usage: node tests/refresh-test.js [base-url]   (default http://localhost:8765/index.html)
// Needs playwright-core (npm i --prefix tests) and Google Chrome. Exits 1 if any check fails.
const {chromium, devices} = require('playwright-core');
const BASE = process.argv[2] || 'http://localhost:8765/index.html';
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let failed = 0;
const ok = (label, pass, info) => { console.log((pass ? 'PASS ' : 'FAIL ') + label + (info ? '  ' + info : '')); if (!pass) failed++; };

(async () => {
  const b = await chromium.launch({executablePath: CHROME, headless: true});
  try {
    const ctx = await b.newContext({...devices['iPhone 13']});
    // Count frames where the home page is visible while the URL points somewhere else.
    await ctx.addInitScript(() => {
      window.__flash = 0;
      const tick = () => {
        const e = document.getElementById('explore');
        if (e && !e.classList.contains('hidden') && !document.documentElement.classList.contains('restoring') &&
            /^#(t|match|team|player|score)=/.test(location.hash)) window.__flash++;
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    const p = await ctx.newPage();
    const errors = [];
    p.on('pageerror', e => errors.push(e.message));

    await p.goto(BASE);
    await p.waitForFunction('typeof cache!=="undefined"&&cache.tournaments.length>0&&cache.fixtures.length>0', {timeout: 30000});
    await p.waitForTimeout(1500);
    const ids = await p.evaluate(() => {
      const t = cache.tournaments.find(t => cache.fixtures.some(f => f.tournament_id === t.id));
      return {t: t.id, f: cache.fixtures.find(f => f.tournament_id === t.id).id,
              tm: (cache.teams.find(x => x.tournament_id === t.id) || cache.teams[0]).id};
    });

    async function check(label, open, probe) {
      await p.evaluate(open);
      await p.waitForTimeout(400);
      const hash = await p.evaluate(() => location.hash);
      await p.evaluate(() => { window.__flash = 0; });
      await p.reload();
      try {
        await p.waitForFunction(probe, {timeout: 15000});
        await p.waitForTimeout(2500); // let the cloud load finish: it must not move the page
        const still = await p.evaluate(probe);
        const flash = await p.evaluate(() => window.__flash);
        ok(label, still && flash === 0 && !(await p.evaluate(() => document.documentElement.classList.contains('restoring'))),
           `hash=${hash} homeFlashFrames=${flash} stayed=${still}`);
      } catch (e) {
        ok(label, false, await p.evaluate(() => JSON.stringify({view, hash: location.hash,
          vis: document.querySelector('main>section:not(.hidden)')?.id})));
      }
    }

    await check('tournament points tab', `openTournament('${ids.t}');renderTournament('${ids.t}','POINTS')`,
      `view.kind==='tournament'&&view.tab==='POINTS'&&!document.getElementById('centre').classList.contains('hidden')`);
    await check('match scorecard', `openMatch('${ids.f}').then(()=>renderMatchView('${ids.f}','SCORECARD'))`,
      `view.kind==='match'&&view.id==='${ids.f}'&&view.tab==='SCORECARD'`);
    await check('team page', `openTeam('${ids.tm}')`,
      `view.kind==='team'&&!document.getElementById('entityDetail').classList.contains('hidden')`);
    await check('players section', `show('players')`, `!document.getElementById('players').classList.contains('hidden')`);
    await check('home', `show('explore')`, `!document.getElementById('explore').classList.contains('hidden')`);

    // Scorer: reload on #score= must call scoreMatch again (login/permission stubbed).
    await ctx.addInitScript(() => {
      window.__scoreCalls = [];
      const iv = setInterval(() => {
        if (typeof scoreMatch === 'function' && !window.__stubbed) {
          window.__stubbed = 1;
          window.scoreMatch = async id => { __scoreCalls.push(id); view = {kind: 'scoring', id, tab: ''}; };
          window.myId = () => 'me'; window.canScoreFixture = () => true; window.matchStatus = () => 'live';
          clearInterval(iv);
        }
      }, 1);
    });
    await p.evaluate(h => history.replaceState(null, '', h), '#score=' + ids.f);
    await p.reload();
    await p.waitForTimeout(6000);
    const s = await p.evaluate(() => ({calls: __scoreCalls.length, kind: view.kind, hash: location.hash}));
    ok('scorer returns to scoring pad', s.calls >= 1 && s.kind === 'scoring', JSON.stringify(s));

    // Navigating while the page is still loading must not be pulled back.
    await p.evaluate(h => history.replaceState(null, '', h), '#t=' + ids.t + '&tab=POINTS');
    await p.reload();
    await p.waitForFunction(`view.kind==='tournament'`, {timeout: 15000});
    await p.evaluate(`show('players')`);
    await p.waitForTimeout(6000);
    ok('no pull-back after navigating during load',
       await p.evaluate(`!document.getElementById('players').classList.contains('hidden')`));

    ok('no page errors', errors.length === 0, errors.join(' | '));
  } finally {
    await b.close();
  }
  console.log(failed ? `\n${failed} check(s) FAILED` : '\nAll refresh checks passed');
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
