-- companion/db.lua
-- Historical store for the Companion. Sessions, fights, per-ability rollups,
-- raw events (pruned), and XP/AA snapshots. Backed by lsqlite3 (the MQ-blessed
-- native path). Patterns mirror rgmercs/utils/config_db.lua: retryable open,
-- busy_timeout, prepared statements, batched transactions.

local mq          = require('mq')
local BlackBox    = require('companion.blackbox')
local ok, sqlite  = pcall(require, 'lsqlite3')
if not ok then
    -- not loaded yet — pull it from the MQ LuaRocks repo, then retry
    local pmOk, PackageMan = pcall(require, 'mq.PackageMan')
    if pmOk and PackageMan then
        sqlite = PackageMan.Require('lsqlite3')
        ok = sqlite ~= nil
    end
end
if not ok or not sqlite then
    error("companion/db: lsqlite3 unavailable. Install it once with: /lua run <any script that does> PackageMan.Require('lsqlite3')")
end

local DB          = {}
DB.__index        = DB

local SCHEMA      = [[
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;

    CREATE TABLE IF NOT EXISTS session (
        id         INTEGER PRIMARY KEY,
        server     TEXT    NOT NULL,
        character  TEXT    NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at   INTEGER
    );

    CREATE TABLE IF NOT EXISTS fight (
        id             INTEGER PRIMARY KEY,
        session_id     INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        started_at     INTEGER NOT NULL,
        ended_at       INTEGER NOT NULL,
        duration       REAL    NOT NULL,
        zone           TEXT,
        primary_target TEXT,
        is_raid        INTEGER NOT NULL DEFAULT 0,
        player_dmg     INTEGER NOT NULL DEFAULT 0,
        pet_dmg        INTEGER NOT NULL DEFAULT 0,
        other_dmg      INTEGER NOT NULL DEFAULT 0,
        total_dmg      INTEGER NOT NULL DEFAULT 0,
        dps            REAL    NOT NULL DEFAULT 0,
        player_dps     REAL    NOT NULL DEFAULT 0,
        incoming       INTEGER NOT NULL DEFAULT 0,
        deaths         INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_fight_session ON fight(session_id);
    CREATE INDEX IF NOT EXISTS idx_fight_dps     ON fight(dps);
    CREATE INDEX IF NOT EXISTS idx_fight_ended   ON fight(ended_at);

    CREATE TABLE IF NOT EXISTS fight_ability (
        id       INTEGER PRIMARY KEY,
        fight_id INTEGER NOT NULL REFERENCES fight(id) ON DELETE CASCADE,
        source   TEXT    NOT NULL,
        ability  TEXT    NOT NULL,
        kind     TEXT    NOT NULL,
        total    INTEGER NOT NULL DEFAULT 0,
        hits     INTEGER NOT NULL DEFAULT 0,
        misses   INTEGER NOT NULL DEFAULT 0,
        crits    INTEGER NOT NULL DEFAULT 0,
        resists  INTEGER NOT NULL DEFAULT 0,
        min_hit  INTEGER NOT NULL DEFAULT 0,
        max_hit  INTEGER NOT NULL DEFAULT 0,
        is_pet   INTEGER NOT NULL DEFAULT 0,
        mods     TEXT,
        over_total INTEGER NOT NULL DEFAULT 0,
        hist     TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_ability_fight ON fight_ability(fight_id);
    CREATE INDEX IF NOT EXISTS idx_ability_name  ON fight_ability(ability);
    CREATE INDEX IF NOT EXISTS idx_ability_source ON fight_ability(source);

    CREATE TABLE IF NOT EXISTS fight_cast (
        id          INTEGER PRIMARY KEY,
        fight_id    INTEGER NOT NULL REFERENCES fight(id) ON DELETE CASCADE,
        source      TEXT    NOT NULL,
        spell       TEXT    NOT NULL,
        kind        TEXT,
        casts       INTEGER NOT NULL DEFAULT 0,
        fizzles     INTEGER NOT NULL DEFAULT 0,
        interrupts  INTEGER NOT NULL DEFAULT 0,
        blocked     INTEGER NOT NULL DEFAULT 0,
        activations INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_cast_fight ON fight_cast(fight_id);
    CREATE INDEX IF NOT EXISTS idx_cast_source ON fight_cast(source, spell);

    CREATE TABLE IF NOT EXISTS smartheal_decision (
        id       INTEGER PRIMARY KEY,
        fight_id INTEGER NOT NULL REFERENCES fight(id) ON DELETE CASCADE,
        seq      INTEGER NOT NULL DEFAULT 0,
        spell    TEXT,
        target   TEXT,
        tier     TEXT,
        trigger  TEXT,
        pct      REAL,
        dps      REAL,
        result   TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_shdec_fight ON smartheal_decision(fight_id);

    CREATE TABLE IF NOT EXISTS event (
        id       INTEGER PRIMARY KEY,
        fight_id INTEGER NOT NULL REFERENCES fight(id) ON DELETE CASCADE,
        t        REAL    NOT NULL,
        source   TEXT,
        target   TEXT,
        ability  TEXT,
        kind     TEXT,
        amount   INTEGER,
        crit     INTEGER,
        outcome  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_event_fight ON event(fight_id);
    -- NB: idx_event_kind_fight is deliberately NOT here -- see _ensureKindIndex.

    CREATE TABLE IF NOT EXISTS death (
        id        INTEGER PRIMARY KEY,
        fight_id  INTEGER NOT NULL REFERENCES fight(id) ON DELETE CASCADE,
        t         REAL    NOT NULL,
        killer    TEXT,
        cause     TEXT,
        narrative TEXT,
        hp_curve  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_death_fight ON death(fight_id);

    CREATE TABLE IF NOT EXISTS death_sample (
        id            INTEGER PRIMARY KEY,
        death_id      INTEGER NOT NULL REFERENCES death(id) ON DELETE CASCADE,
        t             REAL    NOT NULL,
        hp            REAL,
        mana          REAL,
        endur         REAL,
        aggro         REAL,
        aggro2        REAL,
        aggro2_name   TEXT,
        target        TEXT,
        target_pct    REAL,
        tot           TEXT,
        xtargets      INTEGER,
        casting       TEXT,
        invuln        TEXT,
        buff_count    INTEGER,
        buffs_dropped TEXT,
        flags         TEXT,
        grp           TEXT,
        tank          TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_dsample_death ON death_sample(death_id);

    CREATE TABLE IF NOT EXISTS xp_snapshot (
        id         INTEGER PRIMARY KEY,
        session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        t          INTEGER NOT NULL,
        level      INTEGER,
        aa         INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_xp_session ON xp_snapshot(session_id);

    CREATE TABLE IF NOT EXISTS pref (
        key   TEXT PRIMARY KEY,
        value TEXT
    );
]]

---@param path string  full path to the .db file
---@return table|nil
function DB.new(path)
    local db = nil
    local deadline = mq.gettime() + 5000
    while not db and mq.gettime() < deadline do
        db = sqlite.open(path, bit32.bor(sqlite.OPEN_READWRITE, sqlite.OPEN_CREATE, sqlite.OPEN_NOMUTEX))
        if not db then mq.delay(50) end
    end
    if not db then
        printf('\ar[companion] failed to open db at %s', path)
        return nil
    end
    db:busy_timeout(750)
    local self = setmetatable({ _db = db, _sessionId = nil, _path = path, _eventQueue = {} }, DB)
    self:_exec(SCHEMA)
    -- migrations for DBs created before a column existed
    self:_ensureColumn('fight_ability', 'is_pet', 'INTEGER NOT NULL DEFAULT 0')
    self:_ensureColumn('fight_ability', 'mods', 'TEXT')
    self:_ensureColumn('fight_ability', 'over_total', 'INTEGER NOT NULL DEFAULT 0')
    self:_ensureColumn('fight_ability', 'hist', 'TEXT')
    self:_ensureColumn('fight', 'heal_total', 'INTEGER NOT NULL DEFAULT 0')
    self:_ensureColumn('fight', 'overheal', 'INTEGER NOT NULL DEFAULT 0')
    self:_ensureColumn('fight', 'mainhand', 'TEXT')
    self:_ensureColumn('fight', 'offhand', 'TEXT')
    self:_ensureColumn('fight', 'mob_max_hp', 'REAL')
    self:_ensureColumn('fight', 'mob_hp_weight', 'REAL')
    self:_ensureColumn('fight', 'sh_min_hp',    'REAL')
    self:_ensureColumn('fight', 'sh_emerg_sec', 'REAL')
    self:_ensureColumn('fight', 'sh_casts',     'INTEGER')
    self:_ensureColumn('fight', 'sh_summary',   'TEXT')
    self:_ensureColumn('fight', 'killed',       'INTEGER NOT NULL DEFAULT 0') -- primary target slain
    self:_ensureColumn('death', 'character',    'TEXT') -- NULL = the session's own character; else a peer's death
    self:_ensureColumn('fight', 'mob_min_hp',   'REAL')                       -- lowest target HP% seen
    self:_ensureKindIndex()
    return self
end

-- recentDeaths() picks ~400 kind='death' rows out of millions of events.
-- Without an index on kind SQLite walks every event row of every fight
-- (measured: 165ms vs 0.4ms on a 9M-row DB).
--
-- Kept out of SCHEMA on purpose. Building it on an existing large DB took
-- 14.5s and holds the write lock the whole time; run inside the SCHEMA blob
-- that would (a) blow past every other boxed client's 750ms busy_timeout and
-- (b) fail their entire multi-statement schema exec, not just this statement.
-- So: check first (no lock), announce the pause, and let a BUSY loser skip
-- quietly -- whoever wins builds it once and everyone finds it next launch.
-- Prefer building it while logged out: tools/build_kind_index.lua.
function DB:_ensureKindIndex()
    local stmt = self:_prepare(
        "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_event_kind_fight';")
    if not stmt then return end
    local exists = false
    for _ in stmt:nrows() do exists = true end
    stmt:finalize()
    if exists then return end

    printf('\ay[companion]\ax building a one-time index on the events table -- ' ..
        'the client may pause for ~15s. This happens once.')
    local res = self._db:exec("CREATE INDEX IF NOT EXISTS idx_event_kind_fight ON event(kind, fight_id);")
    if res == sqlite.OK then
        printf('\ag[companion]\ax index built; death history queries are ~400x faster now.')
    elseif res == sqlite.BUSY then
        -- Another client is building it (or holds the write lock). Harmless:
        -- the query just stays slow until the next launch finds the index.
        printf('\ay[companion]\ax index build deferred (db busy) -- will retry next load.')
    else
        printf('\ar[companion]\ax index build failed (%d): %s', res, self._db:errmsg())
    end
end

-- Add `col` to `tbl` if it isn't already present (idempotent migration).
function DB:_ensureColumn(tbl, col, decl)
    local stmt = self:_prepare(string.format("PRAGMA table_info(%s);", tbl))
    if not stmt then return end
    local found = false
    for row in stmt:nrows() do if row.name == col then found = true end end
    stmt:finalize()
    if not found then
        self:_exec(string.format("ALTER TABLE %s ADD COLUMN %s %s;", tbl, col, decl))
    end
end

function DB:_exec(sql)
    local res = self._db:exec(sql)
    -- BUSY is a failure too: treating it as OK once let saveFight run with no
    -- transaction open ("cannot commit - no transaction is active", silent row
    -- loss) when several characters' instances saved the same kill at once.
    if res ~= sqlite.OK then
        printf('\ar[companion] db exec error (%d): %s', res, self._db:errmsg())
        return false
    end
    return true
end

-- Open a write transaction, waiting politely for the write lock. All boxed
-- characters share one companion.db, so simultaneous fight saves contend.
-- sqlite's busy_timeout wait blocks the game thread; keep the long waiting in
-- mq.delay (yields to the client) between retries instead.
function DB:_beginImmediate()
    for attempt = 1, 6 do
        local res = self._db:exec("BEGIN IMMEDIATE TRANSACTION;")
        if res == sqlite.OK then return true end
        if res ~= sqlite.BUSY then
            printf('\ar[companion] db begin error (%d): %s', res, self._db:errmsg())
            return false
        end
        if attempt < 6 then mq.delay(150) end
    end
    printf('\ar[companion] db busy: another instance held the write lock too long.')
    return false
end

function DB:_prepare(sql)
    local stmt = self._db:prepare(sql)
    if not stmt then
        printf('\ar[companion] db prepare error: %s\n  %s', self._db:errmsg(), sql)
    end
    return stmt
end

-- Collect all rows of a prepared+bound statement as an array of hash tables.
local function collectRows(stmt)
    local rows = {}
    if not stmt then return rows end
    for row in stmt:nrows() do rows[#rows + 1] = row end
    stmt:finalize()
    return rows
end

local function b(v) return v and 1 or 0 end

-- SQL fragment scoping fight rows to the current server+character's sessions.
-- Bind with DB:_bindChar(stmt, n) → next free bind index.
local CHAR_SESSIONS = "(SELECT id FROM session WHERE server=? AND character=?)"

function DB:_bindChar(stmt, n)
    stmt:bind(n, self._server or 'unknown')
    stmt:bind(n + 1, self._char or 'unknown')
    return n + 2
end

-- ── sessions ──────────────────────────────────────────────────────────
-- Identity alone (no session row): history queries scope to it. A box that
-- does not record fights (Settings > record) sets this and never starts a
-- session, so saveFight/snapshotXp no-op while the history stays readable.
function DB:setIdentity(server, character)
    self._server, self._char = server or 'unknown', character or 'unknown'
end

function DB:startSession(server, character)
    if self._sessionId then return self._sessionId end -- already recording
    self:setIdentity(server, character)
    local stmt = self:_prepare("INSERT INTO session(server, character, started_at) VALUES(?,?,?);")
    if not stmt then return nil end
    stmt:bind(1, self._server)
    stmt:bind(2, self._char)
    stmt:bind(3, os.time())
    local rc = stmt:step(); stmt:finalize()
    if rc ~= sqlite.DONE then
        -- without this guard a BUSY here left _sessionId pointing at a stale
        -- rowid and every later write failed its FK check silently
        printf('\ar[companion] db session insert failed (%d): %s — fights will not be recorded', rc, self._db:errmsg())
        return nil
    end
    self._sessionId = self._db:last_insert_rowid()
    return self._sessionId
end

function DB:endSession()
    if not self._sessionId then return end
    local stmt = self:_prepare("UPDATE session SET ended_at=? WHERE id=?;")
    if not stmt then return end
    stmt:bind(1, os.time()); stmt:bind(2, self._sessionId)
    stmt:step(); stmt:finalize()
end

function DB:sessionId() return self._sessionId end

-- ── fights ────────────────────────────────────────────────────────────
-- Persist a finalized fight, its ability rollups, and its raw events in one
-- transaction. `fight` is the table produced by combat.finalize().
---@param fight table
---@return integer|nil fightId
function DB:saveFight(fight)
    if not self._sessionId then return nil end
    if not self:_beginImmediate() then
        printf('\ar[companion]\ax fight vs %s not saved.', tostring(fight.primary_target))
        return nil
    end

    local fs = self:_prepare([[
        INSERT INTO fight(session_id, started_at, ended_at, duration, zone, primary_target, is_raid,
                          player_dmg, pet_dmg, other_dmg, total_dmg, dps, player_dps, incoming, deaths,
                          heal_total, overheal, mainhand, offhand, mob_max_hp, mob_hp_weight,
                          sh_min_hp, sh_emerg_sec, sh_casts, sh_summary, killed, mob_min_hp)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    ]])
    if not fs then self:_exec("ROLLBACK;") return nil end
    fs:bind(1, self._sessionId)
    fs:bind(2, fight.started_at)
    fs:bind(3, fight.ended_at)
    fs:bind(4, fight.duration)
    fs:bind(5, fight.zone)
    fs:bind(6, fight.primary_target)
    fs:bind(7, b(fight.is_raid))
    fs:bind(8, fight.player_dmg)
    fs:bind(9, fight.pet_dmg)
    fs:bind(10, fight.other_dmg)
    fs:bind(11, fight.total_dmg)
    fs:bind(12, fight.dps)
    fs:bind(13, fight.player_dps)
    fs:bind(14, fight.incoming)
    fs:bind(15, fight.deaths)
    fs:bind(16, fight.heal_total or 0)
    fs:bind(17, fight.overheal or 0)
    fs:bind(18, fight.mainhand)
    fs:bind(19, fight.offhand)
    fs:bind(20, fight.mob_max_hp)
    fs:bind(21, fight.mob_hp_weight or 0)
    fs:bind(22, fight.sh_min_hp)
    fs:bind(23, fight.sh_emerg_sec)
    fs:bind(24, fight.sh_casts)
    fs:bind(25, fight.sh_summary)
    fs:bind(26, b(fight.killed))
    fs:bind(27, fight.mob_min_hp)
    local rc = fs:step(); fs:finalize()
    if rc ~= sqlite.DONE then
        -- bail before child rows attach to a stale last_insert_rowid
        printf('\ar[companion] db fight insert failed (%d): %s', rc, self._db:errmsg())
        self:_exec("ROLLBACK;")
        return nil
    end
    local fightId = self._db:last_insert_rowid()

    local as = self:_prepare([[
        INSERT INTO fight_ability(fight_id, source, ability, kind, total, hits, misses, crits, resists, min_hit, max_hit, is_pet, mods, over_total, hist)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    ]])
    if as then
        for _, a in ipairs(fight.abilities or {}) do
            as:bind(1, fightId)
            as:bind(2, a.source)
            as:bind(3, a.ability)
            as:bind(4, a.kind)
            as:bind(5, a.total)
            as:bind(6, a.hits)
            as:bind(7, a.misses)
            as:bind(8, a.crits)
            as:bind(9, a.resists)
            as:bind(10, a.min_hit)
            as:bind(11, a.max_hit)
            as:bind(12, b(a.is_pet))
            as:bind(13, a.mods_str or '')
            as:bind(14, a.over or 0)
            as:bind(15, a.hist_str or '')
            as:step(); as:reset()
        end
        as:finalize()
    end

    local cs = self:_prepare([[
        INSERT INTO fight_cast(fight_id, source, spell, kind, casts, fizzles, interrupts, blocked, activations)
        VALUES(?,?,?,?,?,?,?,?,?);
    ]])
    if cs then
        for _, c in ipairs(fight.casts or {}) do
            cs:bind(1, fightId)
            cs:bind(2, c.source)
            cs:bind(3, c.spell)
            cs:bind(4, c.kind)
            cs:bind(5, c.casts)
            cs:bind(6, c.fizzles)
            cs:bind(7, c.interrupts)
            cs:bind(8, c.blocked)
            cs:bind(9, c.activations)
            cs:step(); cs:reset()
        end
        cs:finalize()
    end

    if fight.sh_decisions and #fight.sh_decisions > 0 then
        local ds = self:_prepare([[
            INSERT INTO smartheal_decision(fight_id, seq, spell, target, tier, trigger, pct, dps, result)
            VALUES(?,?,?,?,?,?,?,?,?);
        ]])
        if ds then
            for _, d in ipairs(fight.sh_decisions) do
                ds:bind(1, fightId)
                ds:bind(2, d.seq or 0)
                ds:bind(3, d.spell)
                ds:bind(4, d.target)
                ds:bind(5, d.tier)
                ds:bind(6, d.trigger)
                ds:bind(7, d.pct)
                ds:bind(8, d.dps)
                ds:bind(9, d.result)
                ds:step(); ds:reset()
            end
            ds:finalize()
        end
    end

    -- Raw events: the death/kill markers (a handful; recentDeaths' legacy
    -- path reads kind='death') go in this transaction, the bulk is queued and
    -- drained in slices by DB:drainEvents from the main loop -- see there.
    local markers, deferred = {}, {}
    for _, e in ipairs(fight.events or {}) do
        if e.kind == 'death' or e.kind == 'kill' then markers[#markers + 1] = e
        else deferred[#deferred + 1] = e end
    end
    self:_insertEvents(fightId, markers, 1, #markers)

    -- death post-mortem records: one `death` row + its black-box samples
    local okDeaths, deathErr = pcall(function()
        for _, d in ipairs(fight.deaths_detail or {}) do
            local ds = self:_prepare([[
                INSERT INTO death(fight_id, t, killer, cause, narrative, hp_curve, character) VALUES(?,?,?,?,?,?,?);
            ]])
            if ds then
                ds:bind(1, fightId); ds:bind(2, d.t or 0); ds:bind(3, d.killer)
                ds:bind(4, d.cause); ds:bind(5, d.narrative); ds:bind(6, d.hp_curve); ds:bind(7, d.player)
                ds:step(); ds:finalize()
                local deathId = self._db:last_insert_rowid()
                local ss = self:_prepare([[
                    INSERT INTO death_sample(death_id, t, hp, mana, endur, aggro, aggro2, aggro2_name, target, target_pct,
                                             tot, xtargets, casting, invuln, buff_count, buffs_dropped, flags, grp, tank)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                ]])
                if ss then
                    for _, s in ipairs(d.samples or {}) do
                        ss:bind(1, deathId); ss:bind(2, s.t or 0); ss:bind(3, s.hp); ss:bind(4, s.mana); ss:bind(5, s.endur)
                        ss:bind(6, s.aggro); ss:bind(7, s.aggro2); ss:bind(8, s.aggro2Name); ss:bind(9, s.target)
                        ss:bind(10, s.targetPct); ss:bind(11, s.tot); ss:bind(12, s.xtargets); ss:bind(13, s.casting)
                        ss:bind(14, type(s.invuln) == 'string' and s.invuln or nil); ss:bind(15, s.buffCount)
                        ss:bind(16, table.concat(s.buffsDropped or {}, '|'))
                        ss:bind(17, s.flags or ''); ss:bind(18, BlackBox.encodeGroup(s.group)); ss:bind(19, s.tank)
                        ss:step(); ss:reset()
                    end
                    ss:finalize()
                end
            end
        end
    end)
    if not okDeaths then
        printf('\ar[companion]\ax death record failed, fight not saved: %s', tostring(deathErr))
        self:_exec("ROLLBACK;")
        return nil
    end

    if not self:_exec("COMMIT;") then
        self:_exec("ROLLBACK;")
        return nil
    end
    if #deferred > 0 then
        self._eventQueue[#self._eventQueue + 1] = { fightId = fightId, events = deferred, pos = 1 }
    end
    return fightId
end

-- Insert events[from..to] for a fight. Caller owns the transaction.
function DB:_insertEvents(fightId, events, from, to)
    if to < from then return end
    local es = self:_prepare([[
        INSERT INTO event(fight_id, t, source, target, ability, kind, amount, crit, outcome)
        VALUES(?,?,?,?,?,?,?,?,?);
    ]])
    if not es then return end
    for i = from, to do
        local e = events[i]
        es:bind(1, fightId)
        es:bind(2, e.t)
        es:bind(3, e.source)
        es:bind(4, e.target)
        es:bind(5, e.ability)
        es:bind(6, e.kind)
        es:bind(7, e.amount)
        es:bind(8, b(e.crit))
        es:bind(9, e.outcome)
        es:step(); es:reset()
    end
    es:finalize()
end

-- ── deferred event writes ──────────────────────────────────────────────
-- saveFight used to insert up to 4000 event rows inside the fight's
-- transaction: a visible hitch the moment a long fight closed, and a write
-- lock every other boxed client waited on. The fight row and its rollups
-- still commit at once (the history list is right immediately); the raw
-- events sit in self._eventQueue and drainEvents writes `maxRows` of them
-- per call from the main loop, each slice its own short transaction.
-- fightEvents() flushes the fight it is asked for first, so a detail view or
-- post-mortem never sees a half-written log; close() flushes everything.

-- One BEGIN IMMEDIATE attempt, no retry sleep: a slice that loses the lock
-- just runs next tick.
function DB:_tryBegin()
    local res = self._db:exec("BEGIN IMMEDIATE TRANSACTION;")
    if res == sqlite.OK then return true end
    if res ~= sqlite.BUSY then
        printf('\ar[companion] db begin error (%d): %s', res, self._db:errmsg())
    end
    return false
end

---@return boolean  true while queued events remain
function DB:eventsPending() return #self._eventQueue > 0 end

-- Write up to maxRows queued events (default 400). Returns true while more remain.
---@param maxRows integer|nil
---@return boolean more
function DB:drainEvents(maxRows)
    local job = self._eventQueue[1]
    if not job then return false end
    maxRows = maxRows or 400
    if not self:_tryBegin() then return true end
    local to = math.min(#job.events, job.pos + maxRows - 1)
    self:_insertEvents(job.fightId, job.events, job.pos, to)
    if not self:_exec("COMMIT;") then
        self:_exec("ROLLBACK;")
        return true -- slice failed; keep it and retry next tick
    end
    job.pos = to + 1
    if job.pos > #job.events then table.remove(self._eventQueue, 1) end
    return #self._eventQueue > 0
end

-- Drain everything, or just up to and including `fightId`'s job.
---@param fightId integer|nil
function DB:flushEvents(fightId)
    local guard = 0
    while #self._eventQueue > 0 and guard < 10000 do
        guard = guard + 1
        if fightId then
            local found = false
            for _, j in ipairs(self._eventQueue) do if j.fightId == fightId then found = true end end
            if not found then return end
        end
        if not self:drainEvents(4000) and #self._eventQueue > 0 then
            -- BUSY: another client holds the lock; wait briefly and retry
            mq.delay(50)
        end
    end
end

-- Most recent fights (newest first), joined with nothing else.
---@param limit integer
---@return table
function DB:recentFights(limit)
    local stmt = self:_prepare([[
        SELECT id, started_at, duration, zone, primary_target, is_raid,
               player_dmg, pet_dmg, total_dmg, dps, player_dps, incoming, deaths, mainhand, offhand,
               sh_min_hp, sh_emerg_sec, sh_casts, sh_summary, killed, mob_min_hp
        FROM fight WHERE session_id IN ]] .. CHAR_SESSIONS .. [[
        ORDER BY id DESC LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 25)
    return collectRows(stmt)
end

-- Per-target rollup across ALL fights: encounter count, avg/best DPS, avg
-- duration (~time-to-kill), total damage, deaths. Feeds the "By Target" view.
---@param limit integer
function DB:targetAggregates(limit)
    local stmt = self:_prepare([[
        SELECT primary_target AS mob, COUNT(*) AS fights,
               AVG(dps) AS avg_dps, MAX(dps) AS best_dps, AVG(duration) AS avg_dur,
               SUM(total_dmg) AS total_dmg, SUM(deaths) AS deaths
        FROM fight
        WHERE primary_target IS NOT NULL AND primary_target <> ''
          AND session_id IN ]] .. CHAR_SESSIONS .. [[
        GROUP BY primary_target
        ORDER BY fights DESC, total_dmg DESC
        LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 60)
    return collectRows(stmt)
end

-- Per-weapon-set rollup: rank how weapon sets perform. Keyed by mainhand+offhand,
-- reports your avg/best DPS so sets are directly comparable.
---@param limit integer
function DB:weaponAggregates(limit)
    local stmt = self:_prepare([[
        SELECT mainhand, offhand, COUNT(*) AS fights,
               AVG(player_dps) AS avg_pdps, MAX(player_dps) AS best_pdps,
               AVG(dps) AS avg_dps, SUM(total_dmg) AS total_dmg
        FROM fight
        WHERE mainhand IS NOT NULL AND mainhand <> ''
          AND session_id IN ]] .. CHAR_SESSIONS .. [[
        GROUP BY mainhand, offhand
        ORDER BY avg_pdps DESC
        LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 60)
    return collectRows(stmt)
end

-- ── zone runs ─────────────────────────────────────────────────────────
-- One row per (session, zone): every fight of one visit to a zone rolled up,
-- so an instance run (Anguish, a DZ) reads as one combined record. Zones are
-- NULL-safe via COALESCE so the run filter below can bind '' for a missing
-- zone. Combined DPS is over combat time (SUM duration), wall time is
-- first pull to last fight end.
---@param limit integer
---@return table  array of { session_id, zone, fights, started_at, ended_at, combat_sec,
---                         total_dmg, player_dmg, pet_dmg, incoming, deaths, heal_total, is_raid, targets }
function DB:zoneRuns(limit)
    local stmt = self:_prepare([[
        SELECT session_id, COALESCE(zone, '') AS zone, COUNT(*) AS fights,
               MIN(started_at) AS started_at, MAX(ended_at) AS ended_at,
               SUM(duration) AS combat_sec, SUM(total_dmg) AS total_dmg,
               SUM(player_dmg) AS player_dmg, SUM(pet_dmg) AS pet_dmg,
               SUM(incoming) AS incoming, SUM(deaths) AS deaths,
               SUM(heal_total) AS heal_total, MAX(is_raid) AS is_raid,
               COUNT(DISTINCT primary_target) AS targets
        FROM fight WHERE session_id IN ]] .. CHAR_SESSIONS .. [[
        GROUP BY session_id, COALESCE(zone, '')
        ORDER BY started_at DESC
        LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 60)
    return collectRows(stmt)
end

-- Every fight of one zone run (same columns as recentFights), newest first.
---@param sessionId integer
---@param zone string  '' for fights with no zone
function DB:runFights(sessionId, zone)
    local stmt = self:_prepare([[
        SELECT id, started_at, duration, zone, primary_target, is_raid,
               player_dmg, pet_dmg, total_dmg, dps, player_dps, incoming, deaths, mainhand, offhand,
               sh_min_hp, sh_emerg_sec, sh_casts, sh_summary, killed, mob_min_hp
        FROM fight WHERE session_id = ? AND COALESCE(zone, '') = ?
        ORDER BY id DESC LIMIT 500;
    ]])
    if not stmt then return {} end
    stmt:bind(1, sessionId); stmt:bind(2, zone or '')
    return collectRows(stmt)
end

-- Damage per source across a zone run (players + pets; heals excluded), so
-- the run summary can rank everyone over the whole instance.
---@param sessionId integer
---@param zone string
---@return table  array of { source, total, is_pet, fights }
function DB:runSources(sessionId, zone)
    local stmt = self:_prepare([[
        SELECT source, SUM(total) AS total, MAX(is_pet) AS is_pet, COUNT(DISTINCT fight_id) AS fights
        FROM fight_ability
        WHERE kind <> 'heal' AND total > 0
          AND fight_id IN (SELECT id FROM fight WHERE session_id = ? AND COALESCE(zone, '') = ?)
        GROUP BY source
        ORDER BY total DESC
        LIMIT 60;
    ]])
    if not stmt then return {} end
    stmt:bind(1, sessionId); stmt:bind(2, zone or '')
    return collectRows(stmt)
end

-- What a zone run fought: per-target count, damage, avg DPS and deaths.
---@param sessionId integer
---@param zone string
---@return table  array of { mob, fights, total_dmg, avg_dps, avg_dur, deaths }
function DB:runTargets(sessionId, zone)
    local stmt = self:_prepare([[
        SELECT COALESCE(primary_target, 'combat') AS mob, COUNT(*) AS fights,
               SUM(total_dmg) AS total_dmg, AVG(dps) AS avg_dps, AVG(duration) AS avg_dur,
               SUM(deaths) AS deaths, SUM(killed) AS kills, MIN(mob_min_hp) AS min_hp,
               MAX(is_raid) AS is_raid
        FROM fight WHERE session_id = ? AND COALESCE(zone, '') = ?
        GROUP BY COALESCE(primary_target, 'combat')
        ORDER BY total_dmg DESC
        LIMIT 60;
    ]])
    if not stmt then return {} end
    stmt:bind(1, sessionId); stmt:bind(2, zone or '')
    return collectRows(stmt)
end

---@return table|nil  the highest-DPS fight on record
function DB:bestFight()
    local stmt = self:_prepare([[
        SELECT id, started_at, duration, primary_target, dps, total_dmg
        FROM fight WHERE session_id IN ]] .. CHAR_SESSIONS .. [[
        ORDER BY dps DESC LIMIT 1;
    ]])
    if not stmt then return nil end
    self:_bindChar(stmt, 1)
    return collectRows(stmt)[1]
end

-- Average DPS + fight count per session, oldest→newest, for the trend chart.
---@param limit integer
---@return table  array of { session_id, started_at, avg_dps, best_dps, fights }
function DB:sessionDpsSeries(limit)
    local stmt = self:_prepare([[
        SELECT s.id AS session_id, s.started_at AS started_at,
               AVG(f.dps) AS avg_dps, MAX(f.dps) AS best_dps, COUNT(f.id) AS fights
        FROM session s JOIN fight f ON f.session_id = s.id
        WHERE s.server=? AND s.character=?
        GROUP BY s.id
        ORDER BY s.id DESC LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 15)
    local rows = collectRows(stmt)
    -- reverse to chronological
    local out = {}
    for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
    return out
end

-- Lifetime rollup for one ability name across all fights (the "is X worth it"
-- question the log-only tool can't answer across sessions).
---@param ability string
---@return table|nil
function DB:abilityLifetime(ability)
    local stmt = self:_prepare([[
        SELECT ability,
               SUM(total)   AS total,
               SUM(hits)    AS hits,
               SUM(misses)  AS misses,
               SUM(crits)   AS crits,
               SUM(resists) AS resists,
               MAX(max_hit) AS best_hit
        FROM fight_ability WHERE ability = ? COLLATE NOCASE
          AND fight_id IN (SELECT id FROM fight WHERE session_id IN ]] .. CHAR_SESSIONS .. [[);
    ]])
    if not stmt then return nil end
    stmt:bind(1, ability)
    self:_bindChar(stmt, 2)
    return collectRows(stmt)[1]
end

---@param fightId integer
function DB:fightAbilities(fightId)
    local stmt = self:_prepare([[
        SELECT source, ability, kind, total, hits, misses, crits, resists, min_hit, max_hit, is_pet, mods, over_total, hist
        FROM fight_ability WHERE fight_id=? ORDER BY total DESC;
    ]])
    if not stmt then return {} end
    stmt:bind(1, fightId)
    return collectRows(stmt)
end

--- Decision rows for one fight, oldest first. Empty when the bridge was not
--- running, which the UI renders as "no SmartHeals data".
---@param fightId integer
---@return table[] rows
function DB:fightDecisions(fightId)
    local rows = {}
    local stmt = self:_prepare([[
        SELECT seq, spell, target, tier, trigger, pct, dps, result
        FROM smartheal_decision WHERE fight_id=? ORDER BY seq ASC;
    ]])
    if not stmt then return rows end
    stmt:bind(1, fightId)
    for row in stmt:nrows() do rows[#rows + 1] = row end
    stmt:finalize()
    return rows
end

-- Recent deaths (newest first). Post-mortem rows come from `death`; deaths
-- recorded before that table existed fall back to their `event` row (no
-- samples, death_id NULL) so nothing disappears from the list.
---@param limit integer
function DB:recentDeaths(limit)
    local stmt = self:_prepare([[
        SELECT d.id AS death_id, d.fight_id AS fight_id, d.t AS t, d.killer AS killer, d.cause AS cause, d.character AS character,
               f.primary_target AS mob, f.zone AS zone, f.started_at AS started_at, f.duration AS duration,
               f.sh_min_hp AS sh_min_hp, f.sh_emerg_sec AS sh_emerg_sec, f.sh_casts AS sh_casts, f.sh_summary AS sh_summary
        FROM death d JOIN fight f ON f.id = d.fight_id
        WHERE f.session_id IN ]] .. CHAR_SESSIONS .. [[
        UNION ALL
        SELECT NULL AS death_id, e.fight_id AS fight_id, e.t AS t, e.source AS killer, NULL AS cause, NULL AS character,
               f.primary_target AS mob, f.zone AS zone, f.started_at AS started_at, f.duration AS duration,
               f.sh_min_hp AS sh_min_hp, f.sh_emerg_sec AS sh_emerg_sec, f.sh_casts AS sh_casts, f.sh_summary AS sh_summary
        FROM event e JOIN fight f ON f.id = e.fight_id
        WHERE e.kind = 'death' AND f.session_id IN ]] .. CHAR_SESSIONS .. [[
          AND NOT EXISTS (SELECT 1 FROM death d2 WHERE d2.fight_id = e.fight_id)
        ORDER BY started_at DESC, t DESC LIMIT ?;
    ]])
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    n = self:_bindChar(stmt, n)
    stmt:bind(n, limit or 40)
    return collectRows(stmt)
end

-- One death's row + its samples, reshaped for postmortem.analyze.
---@param deathId integer
---@return table|nil { row, samples }
function DB:deathDetail(deathId)
    local stmt = self:_prepare("SELECT id, fight_id, t, killer, cause, narrative, hp_curve, character FROM death WHERE id=?;")
    if not stmt then return nil end
    stmt:bind(1, deathId)
    local row = collectRows(stmt)[1]
    if not row then return nil end
    local ss = self:_prepare([[
        SELECT t, hp, mana, endur, aggro, aggro2, aggro2_name, target, target_pct, tot, xtargets, casting, invuln,
               buff_count, buffs_dropped, flags, grp, tank
        FROM death_sample WHERE death_id=? ORDER BY t ASC;
    ]])
    local samples = {}
    if ss then
        ss:bind(1, deathId)
        for r in ss:nrows() do
            local dropped = {}
            for name in tostring(r.buffs_dropped or ''):gmatch('[^|]+') do dropped[#dropped + 1] = name end
            samples[#samples + 1] = {
                t = r.t, hp = r.hp, mana = r.mana, endur = r.endur, aggro = r.aggro, aggro2 = r.aggro2,
                aggro2Name = r.aggro2_name, target = r.target, targetPct = r.target_pct, tot = r.tot,
                xtargets = r.xtargets, casting = r.casting, invuln = r.invuln, buffCount = r.buff_count,
                buffsDropped = dropped, flags = r.flags or '', group = BlackBox.decodeGroup(r.grp), tank = r.tank,
            }
        end
        ss:finalize()
    end
    return { row = row, samples = samples }
end

---@param fightId integer
function DB:fightCasts(fightId)
    local stmt = self:_prepare([[
        SELECT source, spell, kind, casts, fizzles, interrupts, blocked, activations
        FROM fight_cast WHERE fight_id=? ORDER BY (casts + activations) DESC;
    ]])
    if not stmt then return {} end
    stmt:bind(1, fightId)
    return collectRows(stmt)
end

---@param fightId integer
function DB:fightEvents(fightId)
    self:flushEvents(fightId) -- a queued log for this fight lands first
    local stmt = self:_prepare([[
        SELECT t, source, target, ability, kind, amount, crit, outcome
        FROM event WHERE fight_id=? ORDER BY t ASC;
    ]])
    if not stmt then return {} end
    stmt:bind(1, fightId)
    return collectRows(stmt)
end

-- ── xp / aa ───────────────────────────────────────────────────────────
function DB:snapshotXp(level, aa)
    if not self._sessionId then return end
    local stmt = self:_prepare("INSERT INTO xp_snapshot(session_id, t, level, aa) VALUES(?,?,?,?);")
    if not stmt then return end
    stmt:bind(1, self._sessionId); stmt:bind(2, os.time()); stmt:bind(3, level); stmt:bind(4, aa)
    stmt:step(); stmt:finalize()
end

---@param limit integer
function DB:xpSeries(limit)
    local stmt = self:_prepare(
        "SELECT t, level, aa FROM xp_snapshot WHERE session_id IN " .. CHAR_SESSIONS ..
        " ORDER BY id DESC LIMIT ?;")
    if not stmt then return {} end
    local n = self:_bindChar(stmt, 1)
    stmt:bind(n, limit or 500)
    local rows = collectRows(stmt)
    local out = {}
    for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
    return out
end

-- ── maintenance ───────────────────────────────────────────────────────
-- Drop raw events older than `days` while keeping fight/ability rollups.
-- Prune raw events of fights older than `days`, a bounded slice at a time.
--
-- The old form ("DELETE ... WHERE fight_id IN (SELECT id FROM fight WHERE
-- ended_at < ?)") scanned the whole fight table (no index on ended_at) and
-- deleted every expired row in ONE statement: on a 9M-row event table that is
-- seconds of write lock, which every other boxed client's 750ms busy_timeout
-- turns into failed saves. Now: idx_fight_ended finds expired fights, we walk
-- them in id order from the last fight known to be fully pruned
-- (self._prunedThrough), and delete at most `budget` event rows per call via
-- a rowid subquery (DELETE ... LIMIT needs a non-default SQLite build).
--
-- Returns true when there is more to do; the main loops then call again next
-- tick so the work is spread across ticks and the lock is released between
-- slices. When nothing expired since last time the call is one indexed SELECT.
---@param days integer
---@param budget integer|nil  max event rows per call (default 2000)
---@return boolean more
function DB:pruneEvents(days, budget)
    budget = budget or 2000
    local cutoff = os.time() - (days or 14) * 86400
    self._prunedThrough = self._prunedThrough or 0
    local deleted, fightsChecked = 0, 0
    while deleted < budget and fightsChecked < 50 do
        -- next expired fight past the pruned watermark (fight ids are monotonic)
        local fs = self:_prepare("SELECT id FROM fight WHERE ended_at < ? AND id > ? ORDER BY id LIMIT 1;")
        if not fs then return false end
        fs:bind(1, cutoff); fs:bind(2, self._prunedThrough)
        local fightId = nil
        for row in fs:nrows() do fightId = row.id end
        fs:finalize()
        if not fightId then return false end -- nothing expired beyond the watermark
        fightsChecked = fightsChecked + 1

        local es = self:_prepare(
            "DELETE FROM event WHERE id IN (SELECT id FROM event WHERE fight_id = ? LIMIT ?);")
        if not es then return false end
        es:bind(1, fightId); es:bind(2, budget - deleted)
        local rc = es:step(); es:finalize()
        if rc ~= sqlite.DONE then return true end -- BUSY: try again next tick
        local n = self._db:changes()
        deleted = deleted + n
        if deleted < budget then
            -- fewer rows than asked for: this fight is empty now; its decision
            -- rows go with it and the watermark moves past it
            local ds = self:_prepare("DELETE FROM smartheal_decision WHERE fight_id = ?;")
            if ds then ds:bind(1, fightId); ds:step(); ds:finalize() end
            self._prunedThrough = fightId
        end
    end
    return true
end

-- ── prefs (window geometry, filter/mode UI state) ─────────────────────
---@return table  { key -> value } of all stored prefs
function DB:getAllPrefs()
    local stmt = self:_prepare("SELECT key, value FROM pref;")
    if not stmt then return {} end
    local out = {}
    for row in stmt:nrows() do out[row.key] = row.value end
    stmt:finalize()
    return out
end

function DB:setPref(key, value)
    local stmt = self:_prepare([[
        INSERT INTO pref(key, value) VALUES(?,?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
    ]])
    if not stmt then return end
    stmt:bind(1, key); stmt:bind(2, tostring(value))
    stmt:step(); stmt:finalize()
end

function DB:close()
    if self._db then
        self:flushEvents()
        self:endSession()
        self._db:close()
        self._db = nil
    end
end

return DB
