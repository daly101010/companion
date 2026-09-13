-- Run: luajit tests/test_smartheal_send.lua   (from F:\lua\companion)
-- Asserts the send contract the bridge must satisfy: one message per host
-- script, correct mailbox, and a payload smartheal.lua accepts.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local SH = require('smartheal')

local SCRIPTS = { 'companion', 'maui', 'medley' }
local MAILBOX = 'companion_smartheal'

local sent = {}
local actor = { send = function(_, address, payload)
  sent[#sent + 1] = { script = address.script, mailbox = address.mailbox, payload = payload }
end }

-- the exact helper the bridge uses; duplicated here (not required) because
-- ma_healbridge.lua pulls in mq and the whole sidekick healing stack and
-- cannot be loaded under plain LuaJIT for testing.
local function fan_out(a, payload)
  for _, script in ipairs(SCRIPTS) do
    a:send({ mailbox = MAILBOX, script = script }, payload)
  end
end

fan_out(actor, { kind = 'decision', seq = 1, spell = 'Sacred Light', target = 'Daly',
                 tier = 'single', trigger = 'stable_efficiency', targetPct = 70, targetDps = 500 })

check('one send per host script', #sent == #SCRIPTS, #sent)
local seenScripts = {}
for _, s in ipairs(sent) do
  check('mailbox is companion_smartheal', s.mailbox == MAILBOX, s.mailbox)
  check('no duplicate script', not seenScripts[s.script], s.script)
  seenScripts[s.script] = true
end
for _, want in ipairs(SCRIPTS) do check('reached ' .. want, seenScripts[want] == true) end

-- every fanned payload must be one smartheal.lua accepts
SH.reset(); SH.setPlayer('Freerez')
check('payload accepted by accumulator', SH.onMessage(sent[1].payload) == true)
local snap = SH.snapshot()
check('accumulator saw the decision', snap and snap.tiers.single == 1)

io.write(string.format('smartheal_send: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
