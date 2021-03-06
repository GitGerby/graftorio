prometheus = require("prometheus/prometheus")

function split(inputstr, sep)
  local t={}
  for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
    table.insert(t, str)
  end
  return t
end

train_buckets = {}
bucket_settings = split(settings.startup["graftorio-train-histogram-buckets"].value, ",")
for _, bucket in pairs(bucket_settings) do
  table.insert(train_buckets, tonumber(bucket))
end

gauge_tick = prometheus.gauge("factorio_tick", "game tick")

gauge_item_production_input = prometheus.gauge("factorio_item_production_input", "items produced", {"force", "name"})
gauge_item_production_output = prometheus.gauge("factorio_item_production_output", "items consumed", {"force", "name"})
gauge_fluid_production_input = prometheus.gauge("factorio_fluid_production_input", "fluids produced", {"force", "name"})
gauge_fluid_production_output = prometheus.gauge("factorio_fluid_production_output", "fluids consumed", {"force", "name"})
gauge_kill_count_input = prometheus.gauge("factorio_kill_count_input", "kills", {"force", "name"})
gauge_kill_count_output = prometheus.gauge("factorio_kill_count_output", "losses", {"force", "name"})
gauge_entity_build_count_input = prometheus.gauge("factorio_entity_build_count_input", "entities placed", {"force", "name"})
gauge_entity_build_count_output = prometheus.gauge("factorio_entity_build_count_output", "entities removed", {"force", "name"})
gauge_items_launched = prometheus.gauge("factorio_items_launched_total", "items launched in rockets", {"force", "name"})
gauge_yarm_site_amount = prometheus.gauge("factorio_yarm_site_amount", "YARM - site amount remaining", {"force", "name", "type"})
gauge_yarm_site_ore_per_minute = prometheus.gauge("factorio_yarm_site_ore_per_minute", "YARM - site ore per minute", {"force", "name", "type"})
gauge_yarm_site_remaining_permille = prometheus.gauge("factorio_yarm_site_remaining_permille", "YARM - site permille remaining", {"force", "name", "type"})

gauge_train_trip_time = prometheus.gauge("factorio_train_trip_time", "train trip time", {"from", "to", "train_id"})
gauge_train_wait_time = prometheus.gauge("factorio_train_wait_time", "train wait time", {"from", "to", "train_id"})
histogram_train_trip_time = prometheus.histogram("factorio_train_trip_time_groups", "train trip time", {"from", "to", "train_id"}, train_buckets)
histogram_train_wait_time = prometheus.histogram("factorio_train_wait_time_groups", "train wait time", {"from", "to", "train_id"}, train_buckets)

gauge_train_direct_loop_time = prometheus.gauge("factorio_train_direct_loop_time", "train direct loop time", {"a", "b"})
histogram_train_direct_loop_time = prometheus.histogram("factorio_train_direct_loop_time_groups", "train direct loop time", {"a", "b"}, train_buckets)

gauge_train_arrival_time = prometheus.gauge("factorio_train_arrival_time", "train arrival time", {"station"})
histogram_train_arrival_time = prometheus.histogram("factorio_train_arrival_time_groups", "train arrival time", {"station"}, train_buckets)

local function handleYARM(site)
  gauge_yarm_site_amount:set(site.amount, {site.force_name, site.site_name, site.ore_type})
  gauge_yarm_site_ore_per_minute:set(site.ore_per_minute, {site.force_name, site.site_name, site.ore_type})
  gauge_yarm_site_remaining_permille:set(site.remaining_permille, {site.force_name, site.site_name, site.ore_type})
end

local function hookupYARM()
  if global.yarm_enabled then
    script.on_event(remote.call("YARM", "get_on_site_updated_event_id"), handleYARM)
  end
end

script.on_init(function()
  global.yarm_enabled = false

  if game.active_mods["YARM"] then
    global.yarm_enabled = true
  end

  hookupYARM()
  register_events()
end)

script.on_load(function()
  register_events()
end)

script.on_configuration_changed(function(event)
  if game.active_mods["YARM"] then
    global.yarm_enabled = true
  else
    global.yarm_enabled = false
  end

  hookupYARM()
end)

train_trips = {}
arrivals = {}
watched_train = 0
watched_station = ""
local function watch_train(event, msg)
  if event.train.id == watched_train then
    game.print(msg)
  end
end

local function watch_station(event, msg)
  if event.train.path_end_stop.backer_name == watched_station then
    game.print(msg)
  end
end

local function create_train(event)
  if event.train.path_end_stop == nil then
    return
  end

  -- {source station, tick it departed there, tick last begun waiting, total ticks spent waiting}
  train_trips[event.train.id] = {event.train.path_end_stop.backer_name, game.tick, 0, 0}
  -- watch_train(event, "begin tracking " .. event.train.id)
end

local function create_station(event)
  if event.train.path_end_stop == nil then
    return
  end
  
  -- {last arrival tick}
  arrivals[event.train.path_end_stop.backer_name] = {0}
  -- watch_station(event, "created station " .. event.train.path_end_stop.backer_name)
end

local function reset_train(event)
  if event.train.path_end_stop == nil then
    return
  end

  train_trips[event.train.id] = {event.train.path_end_stop.backer_name, game.tick, 0, 0}
end

seen = {}
local function direct_loop(event, duration, labels)
  from = labels[1]
  to = labels[2]
  train_id = labels[3]
  
  if seen[train_id] == nil then
    seen[train_id] = {}
  end
  
  if seen[train_id][from] == nil then
    seen[train_id][from] = {}
  end

  if seen[train_id][from][to] then
    total = (game.tick - seen[train_id][from][to]) / 60
    
    sorted = {from, to}
    table.sort(sorted)

    -- watch_train(event, sorted[1] .. ":" .. sorted[2] .. " total " .. total)

    gauge_train_direct_loop_time:set(total, sorted)
    histogram_train_direct_loop_time:observe(total, sorted)
  end

  if seen[train_id][to] and seen[train_id][to][from] then
    -- watch_train(event, from .. ":" .. to .. " lap " .. (game.tick - seen[train_id][to][from]) / 60)
  end

  seen[train_id][from][to] = game.tick
end

local function track_arrival(event)
  if event.train.path_end_stop == nil then
    return
  end

  if arrivals[event.train.path_end_stop.backer_name] == nil then
    create_station(event)
  end

  -- watch_station(event, "arrived at " .. event.train.path_end_stop.backer_name)
  if arrivals[event.train.path_end_stop.backer_name][1] ~= 0 then
    lag = (game.tick - arrivals[event.train.path_end_stop.backer_name][1]) / 60
    labels = {event.train.path_end_stop.backer_name}

    gauge_train_arrival_time:set(lag, labels)
    histogram_train_arrival_time:observe(lag, labels)

    -- watch_station(event, "lag was " .. lag)
  end

  arrivals[event.train.path_end_stop.backer_name][1] = game.tick
end

function register_events()
  script.on_event(defines.events.on_tick, function(event)
    if event.tick % 600 == 0 then
      gauge_tick:set(game.tick)
      for _, player in pairs(game.players) do
        stats = {
          {player.force.item_production_statistics, gauge_item_production_input, gauge_item_production_output},
          {player.force.fluid_production_statistics, gauge_fluid_production_input, gauge_fluid_production_output},
          {player.force.kill_count_statistics, gauge_kill_count_input, gauge_kill_count_output},
          {player.force.entity_build_count_statistics, gauge_entity_build_count_input, gauge_entity_build_count_output},
        }

        for _, stat in pairs(stats) do
          for name, n in pairs(stat[1].input_counts) do
            stat[2]:set(n, {player.force.name, name})
          end

          for name, n in pairs(stat[1].output_counts) do
            stat[3]:set(n, {player.force.name, name})
          end
        end

        for name, n in pairs(player.force.items_launched) do
          gauge_items_launched:set(n, {player.force.name, name})
        end
      end

      game.write_file("graftorio/game.prom", prometheus.collect(), false)
    end
  end)

  script.on_event(defines.events.on_train_changed_state, function(event)
    if event.train.state == defines.train_state.arrive_station then
      track_arrival(event)
    end

    if train_trips[event.train.id] ~= nil then
      if event.train.state == defines.train_state.arrive_station then
        if event.train.path_end_stop == nil then
          return
        end

        if train_trips[event.train.id][1] == event.train.path_end_stop.backer_name then
          return
        end

        duration = (game.tick - train_trips[event.train.id][2]) / 60
        wait = train_trips[event.train.id][4] / 60

        -- watch_train(event, event.train.id .. ": " .. train_trips[event.train.id][1] .. "->" .. event.train.path_end_stop.backer_name .. " took " .. duration .. "s waited " .. wait .. "s")

        labels = {train_trips[event.train.id][1], event.train.path_end_stop.backer_name, event.train.id}
        
        gauge_train_trip_time:set(duration, labels)
        gauge_train_wait_time:set(wait, labels)
        histogram_train_trip_time:observe(duration, labels)
        histogram_train_wait_time:observe(wait, labels)
        direct_loop(event, duration, labels)

        reset_train(event)
      elseif event.train.state == defines.train_state.on_the_path and event.old_state == defines.train_state.wait_station then
        -- begin moving after waiting at a station
        train_trips[event.train.id][2] = game.tick
        -- watch_train(event, event.train.id .. " leaving for " .. event.train.path_end_stop.backer_name)
      elseif event.train.state == defines.train_state.wait_signal then
        -- waiting at a signal
        train_trips[event.train.id][3] = game.tick
        -- watch_train(event, event.train.id .. " waiting")
      elseif event.old_state == defines.train_state.wait_signal then
        -- begin moving after waiting at a signal
        train_trips[event.train.id][4] = train_trips[event.train.id][4] + (game.tick - train_trips[event.train.id][3])
        -- watch_train(event, event.train.id .. " waited for " .. (game.tick - train_trips[event.train.id][3]) / 60)
        train_trips[event.train.id][3] = 0
      end
    end

    if train_trips[event.train.id] == nil and event.train.state == defines.train_state.arrive_station then
      create_train(event)
    end
  end)
end
