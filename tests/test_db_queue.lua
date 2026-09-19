-- Run: luajit tests/test_db_queue.lua   (from F:\lua\companion)
--
-- saveFight commits the fight row + rollups at once and queues the raw
-- events; drainEvents writes them in bounded slices from the main loop;
-- fightEvents/close flush first. Pinned against a fake lsqlite3 that records
-- every statement, so the split and the slice boundaries are observable.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

-- ── fake lsqlite3: enough surface for DB.new/startSession/saveFight/drain ──
local log = {}          -- executed SQL in order ("BEGIN", "COMMIT", "INSERT event", ...)
local busyBegins = 0    -- how many BEGINs to refuse with BUSY
local fake = { OK = 0, BUSY = 5, DONE = 101, ROW = 100, OPEN_READWRITE = 2, OPEN_CREATE = 4, OPEN_NOMUTEX = 0x8000 }
local function kindOf(sql)
  sql = sql:gsub('^%s+', '')
  if sql:find('^BEGIN') then return 'BEGIN' end
  if sql:find('^COMMIT') then return 'COMMIT' end
  if sql:find('^ROLLBACK') then return 'ROLLBACK' end
  local tbl = sql:match('^INSERT INTO (%w+)')
  if tbl then return 'INSERT ' .. tbl end
  return 'OTHER'
end
local Stmt = {}; Stmt.__index = Stmt
function Stmt:bind(i, v) self.vals[i] = v return fake.OK end
function Stmt:step() log[#log + 1] = self.kind return fake.DONE end
function Stmt:reset() self.vals = {} return fake.OK end
function Stmt:finalize() return fake.OK end
function Stmt:nrows() return function() return nil end end
local Conn = {}; Conn.__index = Conn
function Conn:exec(sql)
  -- the schema blob is many statements; log only the transaction verbs
  for stmt in sql:gmatch('[^;]+') do
    local k = kindOf(stmt)
    if k == 'BEGIN' and busyBegins > 0 then busyBegins = busyBegins - 1; return fake.BUSY end
    if k ~= 'OTHER' then log[#log + 1] = k end
  end
  return fake.OK
end
function Conn:prepare(sql) return setmetatable({ kind = kindOf(sql), vals = {} }, Stmt) end
function Conn:busy_timeout() end
function Conn:errmsg() return 'fake' end
function Conn:last_insert_rowid() return 42 end
function Conn:changes() return 0 end
function Conn:close() end
function fake.open() return setmetatable({}, Conn) end
package.preload['lsqlite3'] = function() return fake end
package.preload['mq'] = function() return { gettime = function() return 0 end, delay = function() end } end
package.preload['companion.blackbox'] = function() return { encodeGroup = function() return '' end } end
_G.printf = function() end
_G.bit32 = _G.bit32 or { bor = function(a, b, c) return (a or 0) + (b or 0) + (c or 0) end }

local DB = require('companion.db')
local db = DB.new('fake.db')
db:startSession('srv', 'Me')

local function count(kind, from)
  local n = 0
  for i = from or 1, #log do if log[i] == kind then n = n + 1 end end
  return n
end
local function fight(nEvents)
  local ev = {}
  for i = 1, nEvents do ev[i] = { t = i, source = 'Me', kind = 'melee', amount = 1, outcome = 'hit' } end
  ev[#ev + 1] = { t = nEvents + 1, source = 'Me', kind = 'kill', amount = 0, outcome = 'kill' }
  return { started_at = 1, ended_at = 2, duration = 1, events = ev, abilities = {} }
end

-- save: the fight commits at once with only the kill marker inside
log = {}
local id = db:saveFight(fight(1000))
check('fight id returned', id == 42)
check('one transaction at save', count('BEGIN') == 1 and count('COMMIT') == 1, count('BEGIN') .. '/' .. count('COMMIT'))
check('only the marker event is written synchronously', count('INSERT event') == 1, count('INSERT event'))
check('the rest is queued', db:eventsPending())

-- drain: bounded slices, each its own transaction
log = {}
local more = db:drainEvents(400)
check('slice of 400 rows', count('INSERT event') == 400 and more, count('INSERT event'))
check('slice is one transaction', count('BEGIN') == 1 and count('COMMIT') == 1)
db:drainEvents(400)
log = {}
more = db:drainEvents(400)
check('last slice writes the remaining 200', count('INSERT event') == 200, count('INSERT event'))
check('queue empty afterwards', more == false and not db:eventsPending())
local before = #log
check('drain on an empty queue is a no-op', db:drainEvents(400) == false and #log == before)

-- BUSY: the slice is kept and retried next tick
db:saveFight(fight(10))
busyBegins = 1
log = {}
check('busy slice reports more without writing', db:drainEvents(400) == true and count('INSERT event') == 0)
check('next tick writes it', db:drainEvents(400) == false and count('INSERT event') == 10)

-- fightEvents flushes that fight's job first (and only up to it)
db:saveFight(fight(5)); db:saveFight(fight(7))
log = {}
db:fightEvents(42) -- both jobs carry id 42 in the fake; the first is enough to satisfy
check('fightEvents flushed a queued job', count('INSERT event') >= 5)

-- close drains whatever is left
db:saveFight(fight(3))
log = {}
db:close()
check('close flushes the queue', count('INSERT event') >= 3 and not db:eventsPending())

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
