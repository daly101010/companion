-- companion/tools/build_kind_index.lua
--
-- One-time: build idx_event_kind_fight on companion.db.
--
-- db.lua builds this on its own at startup if it's missing, but on a large DB
-- that is ~15s of frozen client while it holds the write lock. Running it here
-- instead -- WITH EVERY EQ CLIENT LOGGED OUT -- keeps the pause out of the game.
--
--   Logged out of every character, then from any MQ client:
--     /lua run companion/tools/build_kind_index
--
-- Safe to run twice: the index is created IF NOT EXISTS.
--
-- Why it matters: recentDeaths() picks the ~400 kind='death' rows out of
-- millions of events. Unindexed that is a walk of every event row of every
-- fight (165ms); indexed it is 0.4ms.

local mq = require('mq')

local ok, sqlite = pcall(require, 'lsqlite3')
if not ok or not sqlite then
    local okPm, PackageMan = pcall(require, 'PackageMan')
    if okPm then sqlite = PackageMan.Require('lsqlite3') end
end
if not sqlite then
    printf('\ar[companion]\ax lsqlite3 unavailable; cannot build the index.')
    return
end

local path = string.format('%s/companion.db', mq.configDir)
local db = sqlite.open(path)
if not db then
    printf('\ar[companion]\ax could not open %s', path)
    return
end
db:busy_timeout(30000) -- no other client should hold it, but wait rather than fail

local exists = false
for _ in db:nrows("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_event_kind_fight';") do
    exists = true
end
if exists then
    printf('\ag[companion]\ax idx_event_kind_fight already present -- nothing to do.')
    db:close()
    return
end

local events = 0
for row in db:nrows('SELECT COUNT(*) AS n FROM event;') do events = row.n end
printf('\ay[companion]\ax indexing %d event rows -- this will block until done.', events)

local t0 = os.time()
local res = db:exec("CREATE INDEX IF NOT EXISTS idx_event_kind_fight ON event(kind, fight_id);")
if res == sqlite.OK then
    printf('\ag[companion]\ax index built in %ds. Expect the db file to grow ~15%%.', os.time() - t0)
else
    printf('\ar[companion]\ax build failed (%d): %s', res, db:errmsg())
    printf('\ar[companion]\ax if this says "database is locked", log every character out and retry.')
end
db:close()
