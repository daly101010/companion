-- Run: luajit tests/test_broadcast_event.lua   (from F:\lua\companion)
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

-- fake mq + actors: capture every fan_out send on the event mailbox
local sent = {}
package.preload['mq'] = function() return { gettime = function() return 1000 end } end
package.preload['actors'] = function()
  return { register = function(name, fn)
    return { send = function(_, address, payload)
      if name == 'companion_events' and type(address) == 'table' and address.mailbox == 'companion_events' then
        sent[#sent + 1] = { payload = payload, script = address.script }
      end
    end }
  end }
end
_G.printf = function() end

local G = require('group')
G.init('Calbuss')

local N = #G.EVENT_CONSUMERS

local function scripts(from, to)
  local out = {}
  for i = from, to do out[#out + 1] = sent[i].script end
  return out
end

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

G.broadcastEvent({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'nuke', amount = 0, outcome = 'resist' })
check('resist is broadcast', #sent == N and sent[1].payload.outcome == 'resist' and sent[1].payload.ability == 'Venin')
check('resist fans out to all consumers incl. necrobrain', contains(scripts(1, N), 'necrobrain'))

G.broadcastEvent({ source = 'Calbuss', target = 'a rat', ability = "Vakk`dra's Sickly Mists", kind = 'cast', amount = 0, outcome = 'cast', mine = true })
check('own cast is broadcast', #sent == 2 * N and sent[N + 1].payload.outcome == 'cast' and sent[N + 1].payload.kind == 'cast')
check('own cast fans out to necrobrain', contains(scripts(N + 1, 2 * N), 'necrobrain'))

G.broadcastEvent({ source = 'Daly', target = 'a rat', ability = 'Slash', kind = 'melee', outcome = 'miss' })
check('miss is still dropped', #sent == 2 * N)

G.broadcastEvent({ source = 'Daly', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 120, outcome = 'hit' })
check('hit carries outcome', #sent == 3 * N and sent[2 * N + 1].payload.outcome == 'hit' and sent[2 * N + 1].payload.amount == 120)
check('hit fans out to necrobrain', contains(scripts(2 * N + 1, 3 * N), 'necrobrain'))

io.write(string.format('test_broadcast_event: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
