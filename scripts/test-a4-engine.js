// Finishing and repeating ticks through A4's engine, in a hidden throwaway Obsidian. Run:
//   "$HOME/Projects/A4/06 AI Team/AI Team Knowledge/Scripts/sandbox-safe.py" 280 -- node scripts/test-a4-engine.js
'use strict';
const fs = require('fs'), path = require('path'), assert = require('assert');
const { execFileSync } = require('child_process');
const { withSandboxObsidian } = require(process.env.HOME + '/Projects/A4/06 AI Team/AI Team Knowledge/Scripts/sandbox-obsidian.js');
const DL = process.env.HOME + '/Projects/dateline/.build/debug/Dateline';
const TASKS = '02 Planner/TaskNotes/Tasks/';
const LIVE = process.env.HOME + '/Projects/A4/';
// Picks its notes from the vault by what they are, read only; the sandbox works on copies.
const pick = (test) => { const f = fs.readdirSync(LIVE + TASKS).filter((n) => n.endsWith('.md')).find((n) => test(fs.readFileSync(LIVE + TASKS + n, 'utf8'))); assert.ok(f, 'no suitable note'); return TASKS + f; };
const ONE = pick((s) => /^status: open$/m.test(s) && /^  - task$/m.test(s) && !/^recurrence:/m.test(s));
const REP = pick((s) => /^recurrence: \S/m.test(s) && /^scheduled: \S/m.test(s) && /^  - task$/m.test(s) && !/^reminders:/m.test(s));
const code = (v, p, d) => execFileSync(DL, ['--a4-code', v, p, d || '']).toString().trim();
const wait = async (f, what) => { for (let i = 0; i < 100; i++) { if (await f()) return; await new Promise((r) => setTimeout(r, 200)); } throw new Error('timed out: ' + what); };
(async () => {
  await withSandboxObsidian({ copy: [ONE, REP], plugins: { lifeworld: process.env.HOME + '/Projects/A4/.obsidian/plugins/lifeworld' } }, async (page, ctx) => {
    const v = await page.evaluate(() => app.vault.getName());
    const read = (p) => fs.readFileSync(path.join(ctx.VAULT, p), 'utf8');
    const run = async (c) => JSON.parse(await page.evaluate((s) => (0, eval)(s), c));
    await wait(() => page.evaluate(() => { const pl = app.plugins.plugins; const o = pl.lifeworld && pl.lifeworld.running && pl.lifeworld.running['a4-projects']; return !!(o && o.taskApi && o.taskApi()); }), 'engine ready');
    await wait(() => page.evaluate((p) => { const f = app.vault.getAbstractFileByPath(p); return !!(f && app.metadataCache.getFileCache(f)); }, ONE), 'indexed');
    // a wrong vault name counts as closed
    assert.strictEqual((await run(code('Another vault', ONE))).r, 'closed', 'wrong vault');
    // one-off: done, dated, queued, filed
    assert.strictEqual((await run(code(v, ONE))).r, 'ok', 'complete');
    await wait(() => /^status: done$/m.test(read(ONE)), 'status done');
    assert.match(read(ONE), /^completedDate: \d{4}-\d\d-\d\d$/m);
    const queued = await page.evaluate((p) => app.plugins.plugins.lifeworld.running['a4-projects'].settings.archiveQueue.some((x) => x.taskPath === p), ONE);
    assert.ok(queued, 'in the archive queue');
    await page.evaluate(() => app.plugins.plugins.lifeworld.running['a4-projects'].processArchiveQueue(Date.now() + 6 * 60000));
    const arch = '02 Planner/TaskNotes/Archive/' + path.basename(ONE);
    await wait(() => fs.existsSync(path.join(ctx.VAULT, arch)), 'moved to the Archive');
    assert.match(fs.readFileSync(path.join(ctx.VAULT, arch), 'utf8'), /- archived/);
    assert.strictEqual((await run(code(v, ONE))).r, 'gone', 'moved note answers gone');
    console.log('one-off: done, queued, filed in the Archive');
    // repeating: that day only, the task stays open, second tick takes it back
    const before = read(REP), day = before.match(/^scheduled: (\S+)/m)[1], status = before.match(/^status: (\S+)/m)[1];
    assert.strictEqual((await run(code(v, REP, day))).r, 'ok', 'tick');
    await wait(() => read(REP) !== before, 'repeating written');
    const after = read(REP);
    assert.ok(after.match(/^complete_instances:[\s\S]*?(?=^\S)/m)[0].includes(day), 'the day is ticked');
    assert.strictEqual(after.match(/^status: (\S+)/m)[1], status, 'still ' + status);
    assert.notStrictEqual(after.match(/^scheduled: (\S+)/m)[1], day, 'moved on to the next day');
    console.log('repeating: ticked', day, 'next', after.match(/^scheduled: (\S+)/m)[1]);
    assert.strictEqual((await run(code(v, REP, day))).r, 'ok', 'untick');
    await wait(() => !read(REP).match(/^complete_instances:[\s\S]*?(?=^\S)/m)[0].includes(day), 'unticked');
    console.log('repeating: second tick took it back');
    // a change written on disk reaches Obsidian
    const p2 = path.join(ctx.VAULT, REP);
    fs.writeFileSync(p2 + '.tmp', read(REP).replace(/^priority: \S+/m, 'priority: high')); fs.renameSync(p2 + '.tmp', p2);
    await wait(() => page.evaluate((p) => app.metadataCache.getFileCache(app.vault.getAbstractFileByPath(p))?.frontmatter?.priority === 'high', REP), 'Obsidian sees the file change');
    console.log('a saved change reaches Obsidian');
    // the one-line reminder Dateline writes with a first time
    fs.writeFileSync(p2 + '.tmp', read(REP).replace(/^priority: \S+/m, 'priority: low\nreminders: [{id: rem_1, type: relative, relatedTo: due, offset: PT0M}]')); fs.renameSync(p2 + '.tmp', p2);
    await wait(() => page.evaluate((p) => app.metadataCache.getFileCache(app.vault.getAbstractFileByPath(p))?.frontmatter?.reminders?.[0]?.offset === 'PT0M', REP), 'Obsidian reads the reminder');
    console.log('the reminder line reads in Obsidian');
  });
  console.log('PASS');
})().catch((e) => { console.error('FAIL', e.message); process.exit(1); });
