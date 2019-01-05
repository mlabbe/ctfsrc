pico-8 cartridge // http://www.pico-8.com
version 8
__lua__
--
-- Copyright (C) 2016-2018 Frogtoss Games, Inc.
--
-- CTF by Michael Labbe

-- export with:
-- export ctf.bin -i 76 -s 4 -c 16

dev = false
ent_list = {}
types = {}
tick_count = 0
default_hw = {4,4} -- 8x8 block halfwidths
cam={0,0} -- world top-left
killfloor = -100 -- spike killfloor, set by adding killtouch entities to the level
touch_pairs = {}  -- pairwise touch events for the frame
blueflag_ent = nil
cur_message = nil
cur_music = nil
title={in_title=false,
       starting=false,
       in_ending=false}
timing={
   session_start=0,    -- time() sample at session start
   round_start=0,
}
shake = {frames=0}
 
-- constants
k_left=0
k_right=1
k_up=2
k_down=3
k_jump=4
k_grapple=5

fl_collision=0

pm_moverate = 0.065
pm_jumprate = 0.4
pm_jumpframes = 6
pm_enemymoverate = 0.05
pm_frames_between_jumps = 120
pm_grapplerate = 3.0
pm_invuln_frames = 120
pm_knockback_mag = 0.35
pm_gravity  = 0.105
pm_gravity_resist_multiplier = 0.7

pm_particleframes = 15
pm_flag_return_frames = 60*30
pm_death_delay_frames = 60*2.5

pm_capturelimit = 2

-- base ent
function init_ent(type,x,y)
   local ent = {}
   ent.type = type
   
   ent.px = x
   ent.py = y
   ent.spr = 0
   ent.is_spawned = true
   ent.start_pos = {x,y}
   ent.preserve_on_restart = false

   -- call this to poll killfloor
   ent.is_under_killfloor = function(base)
      return base.py + 8 > killfloor
   end

   if ent.type.init ~= nil then
      ent.type.init(ent)
   end
   add(ent_list, ent)
   return ent
end

function del_ent(ent)
   del(ent_list, ent)
end

--
-- mixins: these are base.mixin, just like base.type
-- is main derived entity type.
--

-- physics integrator
phys = {
   vx = 0,
   vy = 0,
   ax = 0,
   ay = 0,
   force_accum_x = 0,
   force_accum_y = 0,
   impulse_accum_x = 0,
   impulse_accum_y = 0,
   no_clip = false,
   
   integrate=function(base)

      -- fixed unit accum
      base.phys.vx += base.phys.impulse_accum_x
      base.phys.vy += base.phys.impulse_accum_y
      
      local wish_x, wish_y
      if base.phys.no_clip then
         wish_x, wish_y = base.phys.vx, base.phys.vy
      else
         wish_x, wish_y = collide_all(base, base.phys.vx, base.phys.vy, ent_list)
      end

      -- update linear position
      base.px += wish_x
      base.py += wish_y

      -- verlet-style clamp velocity to distance travelled
      if base.type.verlet_clamp ~= nil then
         base.phys.vx = wish_x
         base.phys.vy = wish_y
      end

      -- work out resulting accel from accumulated forces
      local res_ax = (base.phys.ax + base.phys.force_accum_x) 
         * base.type.invmass
      local res_ay = (base.phys.ay + base.phys.force_accum_y)
         * base.type.invmass

      -- update linear velocity from accel
      base.phys.vx += res_ax
      base.phys.vy += res_ay


      -- impose drag relative to mass
      base.phys.vx *= base.type.invmass
      base.phys.vy *= base.type.invmass

      -- zero frame's forces
      base.phys.force_accum_x = 0
      base.phys.force_accum_y = 0
      base.phys.impulse_accum_x = 0
      base.phys.impulse_accum_y = 0
   end,

   add_force=function(base, x, y)
      base.phys.force_accum_x += x
      base.phys.force_accum_y += y
   end,

   reset=function(phys)
      phys.impulse_accum_x = 0
      phys.impulse_accum_y = 0
      phys.force_accum_x = 0
      phys.force_accum_y = 0
      phys.ax = 0
      phys.ay = 0
      phys.vx = 0
      phys.vy = 0
   end,
}

-- entity movement info
emove = {
   is_in_air = true,  -- invalidates standing_on
   landing_this_frame = false,
   face_left=false,
   standing_on=nil, --nil = ground, other is ent index

   apply_gravity=function(base)
      if base.emove.is_in_air then
         base.phys.force_accum_y += pm_gravity
      end
   end,

   set_state_for_tick=function(base)
      local was_in_air = base.emove.is_in_air

      -- fudge scan origin based on facing dir
      local floor_lookup_x = base.px +2
      if base.emove.face_left then floor_lookup_x += 5 end

      -- todo next: fix this in air test
      base.emove.is_in_air = not
         fget(tile_lookup(floor_lookup_x, base.py, 0, 1), fl_collision)

      if base.emove.is_in_air then
         base.emove.standing_on = ent_trace(base.px+4, base.py+9, ent_list)
         if base.emove.standing_on ~= nil then
            add_touch_event(base, base.emove.standing_on)
         end

         base.emove.is_in_air = base.emove.standing_on == nil
         
      end
      
      base.emove.face_left = base.phys ~= nil and base.phys.vx < 0

      base.emove.landing_this_frame = was_in_air and not base.emove.is_in_air
   end,
}


--
-- helpers
--
function vec_dot(u,v)
   return u[1]*v[1]+u[2]*v[2]
end

function vec_distsq(u,v)
   local d={u[1]-v[1],
            u[2]-v[2]}
   return d[1]*d[1]+d[2]*d[2]
end

function vec_dist(u,v)
   return sqrt(vec_distsq(u,v))
end

function vec_mag(v)
   return sqrt(vec_dot(v,v))
end

function vec_norm(v)
   local k = 1.0 / vec_mag(v)
   local out = {v[1]*k, v[2]*k}
   return out
end

function vec_sub(u,v)
   return {u[1]-v[1],u[2]-v[2]}
end

function vec_add(u,v)
   return {u[1]+v[1],u[2]+v[2]}
end

function vec_mul(v,k)
   return {v[1]*k, v[2]*k}
end

function vis_vec2(p, v, mag, col)
   line(p[1], p[2],
        p[1]+(v[1]*mag), p[2]+(v[2]*mag),
        col)
   pset(p[1], p[2], 7)
end

function vis_pt(p, c)
   pset(p[1]+cam[1], p[2]+cam[2], c)
end

function printh_vec2(v)
   printh(v[1]..' x '..v[2])
end

function printh_aabb2(label, min, max)
   printh(label..": ".."["..min[1]..", "..min[2].."]x["..max[1]..", "..max[2].."]")
end

function find_ent_of_type(t)
   for ent in all(ent_list) do
      if ent.type == t then
         return ent
      end
   end
   return nil
end

-- take in world x,y and a tile offset from
-- the tile that resolves to
-- return a tile and its world position top-left
function tile_lookup(x, y, t_off_x, t_off_y)
   local tx = flr(x/8) + t_off_x
   local ty = flr(y/8) + t_off_y
   tile = mget(tx,ty)

   --rect(tx*8, ty*8, (tx*8)+8, (ty*8)+8, 14)
   return tile, tx*8, ty*8
end

-- given world point x, y, return the tile type and
-- top-left world x and y point of the four overlapping
-- tiles.
-- return data structure is an array of four tables,
-- representing up-left, up-right, down-left, down-right
-- each table has tile, world_x, world_y
--
-- subletly: a tile resting exactly on top of the grid
-- will return the top-right corner of the adjacent tiles.
-- 
-- therefore, there is no possibility of returning the
-- same tile for each corner.
function tile_trace(x, y)
   local tx, ty

   local pts = {}
   local c = {0,0, 8,0, 0,8, 8,8}
   local i=1
   while c[i] do
      tx = flr((x+c[i+0])/8)
      ty = flr((y+c[i+1])/8)
      local pt = {mget(tx,ty), tx*8, ty*8}
      add(pts, pt)
      i+=2
   end

   return pts
end

-- trace point x,y against list of ents
-- returning first entity
-- hit or nil if no entities were hit
-- assumes ent bounds are 8px square for perf
function ent_trace(x, y, ents)
   --pset(x+cam[1], y+cam[2], 8)
   for ent in all(ents) do
      if pt_in_ent(ent, x, y) and
         ent.type.can_collide then
         return ent
      end
   end
   return nil
end

function get_player(n)
   return ent_list[n]
end

-- perform sat on 2 aabbs
-- amin and bmin are the top-left corners
-- a_hw and b_hw are halfwidth extents (ex: {4,4} for 8x8)
-- returns {false} if miss, or {true, depth, axis}
-- on hit, where depth is the minimum translation distance magnitude and axis
-- 1=x or 2=y
function aabb_sat(amin, bmin, a_hw, b_hw)
   local amax = {amin[1]+8, amin[2]+8} -- bug bug shouldn't this be a_hw?
   local bmax = {bmin[1]+8, bmin[2]+8}

   local calc_interval = function(amin, amax, bmin, bmax, axis, a_hw, b_hw)
      local center = amin[axis] + (amax[axis] - amin[axis])/2
      local a_interval_min = center - a_hw
      local a_interval_max = center + a_hw

      center = bmin[axis] + (bmax[axis] - bmin[axis])/2
      local b_interval_min = center - b_hw
      local b_interval_max = center + b_hw

      -- intersect interval
      local d0 = a_interval_max - b_interval_min
      local d1 = b_interval_max - a_interval_min
      
      if d0 < 0 or d1 < 0 then return {false} end
      local depth
      
      if d0 < d1 then
         d0 = -d0
         depth = d0
      else
         depth = d1
      end

      return {true, depth, axis}
   end
   

   result_x = calc_interval(amin, amax, bmin, bmax, 1, a_hw[1], b_hw[1])
   if not result_x[1] then return result_x end
   result_y = calc_interval(amin, amax, bmin, bmax, 2, a_hw[2], b_hw[2])
   if not result_y[1] then return result_y end
   
   if abs(result_x[2]) < abs(result_y[2]) then
      --print("return x: "..result_x[2], 10, 56, 3)      
      return result_x
   else
      --print("return y: "..result_y[2], 10, 56, 2)
      return result_y
   end
end

-- boolean test aabb intersection
-- amin, bmin are top-left
-- amax, bmax are bottom-right
function aabb_intersecting(amin, bmin, amax, bmax)
   if amin[1] > bmax[1] then return false end
   if amin[2] > bmax[2] then return false end
   if amax[1] < bmin[1] then return false end
   if amax[2] < bmin[2] then return false end
   return true
end


function pt_in_aabb(min, max, pt)
   if pt[1] < min[1] or pt[1] > max[1] then return false end
   if pt[2] < min[2] or pt[2] > max[2] then return false end
   return true
end

function ent_in_ent(ent1, ent2)
   return aabb_intersecting(
      {ent1.px,   ent1.py},     {ent2.px,   ent2.py},
      {ent1.px+8, ent1.py+8},   {ent2.px+8, ent2.py+8})
end

function pt_in_ent(ent, x, y)
   return pt_in_aabb({ent.px, ent.py}, {ent.px+8, ent.py+8}, {x,y})
end

-- lightweight emove.is_in_air alternative that only checks map
-- to avoid expensive entity search
function is_in_air_maponly(ent)
   return not fget(tile_lookup(ent.px, ent.py, 0, 1), fl_collision)
end


-- shallow copy a table of functions and attributes to use as a mixin
-- for an object.
function mixin_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end


function get_ent_halfwidths(ent)
   -- 8x8 blocks
   local ent_hw
   if ent.type.hw_bounds ~= nil then
      ent_hw = ent.type.hw_bounds
   else
      ent_hw = default_hw
   end

   return ent_hw
end

function collide_map(ent, wish_x, wish_y)
   local ent_hw = get_ent_halfwidths(ent)
   local off = {ent.px + wish_x, ent.py + wish_y}
   
   local pts = tile_trace(off[1], off[2])
   local collide_count = 0
   for i = 1,#pts do
      local tile = pts[i][1]
      local can_collide = fget(tile, collision)

      
      if can_collide then
         sat = aabb_sat(off, {pts[i][2], pts[i][3]}, ent_hw, default_hw)
         if sat[1] then
            off[sat[3]] += sat[2]
         end
      end
   end

   local offset = {off[1]-ent.px, off[2]-ent.py}
   return offset[1], offset[2] 
end

-- collide all ents, also returning on touch events  
function collide_ents(ent1, wish_x, wish_y, ents)
   -- early exit if entity type can't collide
   if ent1.type.can_collide == nil then
      return wish_x, wish_y
   end
   
   local ent1_hw = get_ent_halfwidths(ent1)
   local ent1_off = {ent1.px + wish_x, ent1.py + wish_y}
   
   for ent2 in all(ents) do
      if ent1 ~= ent2 and ent2.type.can_collide and
         ent1.is_spawned and ent2.is_spawned then
         ent2_hw = get_ent_halfwidths(ent2)

         sat = aabb_sat(ent1_off, {ent2.px, ent2.py},
                        ent1_hw, ent2_hw)
         if sat[1] and sat[2] != 0 then
               ent1_off[sat[3]] += sat[2]

               -- knock ent2 back by transferring ent1's velocity
               -- on the axis of collision
               if ent2.phys ~= nil then
                  if sat[3] == 1 then 
                     ent2.phys.impulse_accum_x += ent1.phys.vx
                  elseif sat[3] == 2 then
                     ent2.phys.impulse_accum_y += ent1.phys.vy
                  end
               end

               add_touch_event(ent1, ent2)
         end
      end
   end

   local offset = {ent1_off[1]-ent1.px, ent1_off[2]-ent1.py}
   return offset[1], offset[2]
end

-- collide ent against world geo and then ent_list
-- returning max non-colliding move
function collide_all(ent, wish_x, wish_y, ent_list)
   wish_x, wish_y = collide_map(ent, wish_x, wish_y)

   -- perf: pass in spatially localized ent_list rather than full one
   wish_x, wish_y = collide_ents(ent, wish_x, wish_y, ent_list)
   
   return wish_x, wish_y
end

-- create a pairwise touch event.  each ent can only have one
-- touch event per frame.  the last one wins.
--
-- this enables multiple points in the code to create possibly redundant
-- touch events such as standing-on,
-- avoiding re-running aabb intersection separately for
-- touch and collision cases.
function add_touch_event(ent1, ent2)
   if ent1.type.on_touch ~= nil then
      touch_pairs[ent1] = ent2
   end
   if ent2.type.on_touch ~= nil then
      touch_pairs[ent2] = ent1
   end
end

function exec_touch_events()
   for touch_ent in pairs(touch_pairs) do
      touch_ent.type.on_touch(touch_ent, touch_pairs[touch_ent])
   end
   touch_pairs = {}
end

function add_hud_message(msg)
   cur_message = hud_message
   cur_message.init(cur_message, msg)
end

function print_centerx(msg, y, color)
   local w = #msg * 4
   local x = 64-(w/2)
   print(msg, x, y, color)
end

-- converts seconds into 'm:ss' time str
function time_str(secs)
   local mins = flr(secs/60)
   local secs = flr(secs)%60
   if secs <= 9 then secs = '0'..secs end
   return mins..':'..secs
end

--
-- entity types
--
player = {
   tile=1,
   invmass = 0.92,
   hw_bounds = {3,3}, --
   can_collide = true,  -- necessary to collide with other entities
   verlet_clamp = true, -- v = p1-p0 in integrator.
   
   init=function(base)
      base.phys = phys
      base.emove = emove
      base.spr = 1
      base.jump_frames_left = 0
      base.can_jump = base.emove.is_in_air
      base.is_spawned = false
      base.health = 1
      base.invuln_frames = 0
      base.spawn_frames = 0
      base.lives_frames = 0
      base.lives = 2
   end,
   tick=function(base)
      base.emove.set_state_for_tick(base)

      if not base.is_spawned then
         if base.spawn_frames <= 0 then
            base.type.spawn(base)
            return
         else
            base.spawn_frames -= 1
         end
         return
      end
      
      -- handle input
      if btn(k_left) then
         base.phys.force_accum_x -= pm_moverate
         if base.phys.vx > 0 and not base.emove.is_in_air then
            base.phys.vx *= 0.25
         end
      end
      if btn(k_right) then
         base.phys.force_accum_x += pm_moverate
         if base.phys.vx < 0 and not base.emove.is_in_air then
            base.phys.vx *= 0.25
         end
      end
      if btn(k_jump) then
         if not base.emove.is_in_air then
            if base.can_jump then
               -- do jump
               sfx(0,3)
               base.jump_frames_left = pm_jumpframes
               base.can_jump = false
            end
         else
            -- slow the fall
            base.phys.force_accum_y -= pm_gravity*pm_gravity_resist_multiplier
         end
      else
         if not base.emove.is_in_air then
            base.can_jump = true
         end
      end
      
      if btn(k_grapple) then
         if base.ext_grapple == nil then
            base.ext_grapple = init_ent(extended_grapple, base.px, base.py)
         end
      else
         if base.ext_grapple ~= nil then
            sfx(23,3)
            del_ent(base.ext_grapple)
            base.ext_grapple = nil
         end

      end

      -- continue jumping
      if base.jump_frames_left > 0 then
         base.phys.impulse_accum_y -= pm_jumprate
         base.jump_frames_left -= 1
      end

      -- provide stability on landing
      if base.emove.landing_this_frame then
         base.phys.vy = 0
      end
      
      -- apply world state
      if base.is_under_killfloor(base) then
         base.type.die(base)
      end

      if base.jump_frames_left <= 0 then
         emove.apply_gravity(base)
      end

      base.invuln_frames = max(0, base.invuln_frames-1)
      
      -- integrate
      base.phys.integrate(base)      
   end,
   draw=function(base)
      if base.invuln_frames > 0 and (base.invuln_frames%2)==0 then
         return
      end

      if not base.is_spawned then
         return 
      end

      if base.lives_frames != 0 then
         print("x", base.px+8+cam[1], base.py+2+cam[2], 6)
         print(base.lives, base.px+12+cam[1], base.py+2+cam[2], 7)
         base.lives_frames -= 1
      end
      
      local si = base.spr
      if base.emove.is_in_air then
         si += 2
      end
      if abs(base.phys.vx) > 0.1 and time()%2>1 then
         si += 1
      end

      -- fixme: sprite being forced to box
      --si = 5
      spr(si, base.px+cam[1], base.py+cam[2], 1, 1, base.emove.face_left)
   end,
   spawn=function(base)
      -- look for red flag to spawn at
      if base.lives != 2 then
         sfx(26,3)
      end
      local spawn_point = find_ent_of_type(redflag)
      base.px = spawn_point.px + 9
      base.py = spawn_point.py
      base.is_spawned = true
      base.phys.reset(base.phys)
      base.health = 1
      base.invuln_frames = 0
      add_hud_message("get the blue flag!")
   end,
   on_damage=function(base, attacker_ent)
      if base.invuln_frames > 0 then return end
      base.health -= 1
      base.invuln_frames = pm_invuln_frames
      
      if base.health < 0 then
         base.type.die(base)
      else
         -- knockback
         sfx(29,3)         
         local d = vec_sub({base.px+4, base.py+4}, {attacker_ent.px+4, attacker_ent.py+4})
         local kb = vec_norm(d)
         kb = vec_mul(d, pm_knockback_mag)
         base.phys.force_accum_x += kb[1]
         base.phys.force_accum_y += kb[2]
      end
   end,
   die=function(base)
      sfx(24,3)
      base.type.fx_die(base)
      
      local blueflag = find_ent_of_type(blueflag)
      blueflag.type.on_player_die(blueflag)
      if base.ext_grapple ~= nil then
         del_ent(base.ext_grapple)
         base.ext_grapple = nil
      end

      base.is_spawned = false
      base.spawn_frames = pm_death_delay_frames

      base.lives -= 1
      base.lives_frames = 60*2.5
   end,
   fx_die=function(base)

      local do_particles = function(n,c) 
         local x = base.px+4
         local y = base.py+4
         for i=1,n do
            ent = init_ent(phys_particle, x, y)
            ent.colors = {c}
            ent.lifetime_frames = pm_death_delay_frames
            local rand = rnd(10)/5
            ent.phys.impulse_accum_y -= 2.0 + rand
            ent.phys.force_accum_x = (rnd(10) - 5) * 0.2         
         end
      end

      do_particles(8,9)
      do_particles(4,15)
      do_particles(4,14)            
   end
      
}
add(types, player)

crate = {
   tile = 56,
   invmass = 0.92,
   can_collide = true,
   verlet_clamp = true,
  
   init=function(base)
      base.phys = mixin_copy(phys)
      base.spr = crate.tile
      base.is_in_air = false
   end,

   tick=function(base)
      -- perf: resting crates save time, but we are not checking if a crate is
      -- resting on another.  
      if is_in_air_maponly(base) then
         local search = {base.px+4, base.py+9}

         base.phys.force_accum_y += pm_gravity
      end

      if base.is_under_killfloor(base) then
         del_ent(base)
      end
      if abs(base.phys.impulse_accum_x) > 0 or abs(base.phys.impulse_accum_y) > 0 or
         abs(base.phys.force_accum_x) > 0 or abs(base.phys.force_accum_y) > 0 then
         base.phys.integrate(base)
      end
      
   end,
}
add(types, crate)

redflag = {
   tile = 16,
   init=function(base)
      base.spr = redflag.tile
      base.px -= 4
   end,
   fx_celebrate=function(base, num)
      for i=1,num do
         ent = init_ent(phys_particle)
         ent.px = base.px+4
         ent.py = base.py
         ent.colors = {8,8,10,2,2}
         ent.lifetime_frames = 80

         local rand = rnd(10)/5
         ent.phys.impulse_accum_y -= 5.0 + rand
         ent.phys.force_accum_x = (rnd(10) - 5) * 0.2
         
         --local rand = rnd(10)/5
         
      end
   end,
   
}
add(types, redflag)

blueflag = {
   tile = 17,
   invmass = 0.8,
   init=function(base)
      base.spr = blueflag.tile
      base.flip_image = false
      base.particle_frames = pm_particleframes
      base.phys = mixin_copy(phys)
      base.dropped_return_frames = 0 -- frames until dropped flag is returned
      base.captures = 0
   end,
   on_touch = function(base, touch_ent)
      if touch_ent.type == player then
         base.attach_ent = touch_ent
         base.dropped_return_frames = 0
         add_hud_message("capture the flag!")
         play_music(11)
      end
      if touch_ent.type == redflag then
         base.type.return_flag(base, true)
         touch_ent.type.fx_celebrate(touch_ent, 20)
      end
   end,
   tick = function(base)
      if base.attach_ent == nil then
         local player = get_player(1)
         -- check for overlap with player and create touch event
         if player.is_spawned and ent_in_ent(base, player) then
            add_touch_event(base, player)
         end

         if base.is_under_killfloor(base) then
            sfx(25,2)            
            base.type.return_flag(base, false)
         end
      
         if base.dropped_return_frames > 0 then
            base.dropped_return_frames -= 1
            if is_in_air_maponly(base) then
               base.phys.force_accum_y += pm_gravity
            end
            base.phys.integrate(base)
         else
            if base.px != base.start_pos[1] and
               base.py != base.start_pos[2] then
                  sfx(25,3)
                  base.type.return_flag(base, false)
            end
         end
         return
      end
      base.px = base.attach_ent.px+6
      base.py = base.attach_ent.py-2
      base.flip_image = base.attach_ent.emove.face_left
      if not base.flip_image then
         base.px -= 12
      end

      -- track the redflag
      if base.redflag == nil then
         base.redflag = find_ent_of_type(redflag)
      end
      
      -- test the player touching the red flag, but fire the event
      -- with the blue flag as the toucher
      if ent_in_ent(get_player(1), base.redflag) then
         add_touch_event(base, base.redflag)
      end

      base.particle_frames -= 1
      if base.particle_frames == 0 then
         base.particle_frames = pm_particleframes + flr(rnd(5))

         local num_particles = flr(rnd(3))+1
         for i = 1,num_particles do
            base.type.init_flag_particle(base)
         end
      end
   end,
   init_flag_particle = function(base)
      ent = init_ent(phys_particle)
      ent.px = base.px + rnd(2)
      ent.py = base.py

      local rand = rnd(10)/5
      ent.phys.impulse_accum_y -= 0.5 + rand
      ent.phys.force_accum_x = get_player(1).phys.vx * -1.2
      return ent
   end,
   draw = function(base)
      spr(base.spr, base.px+cam[1], base.py+cam[2], 1, 1, base.flip_image, false)
   end,
   on_player_die=function(base)
      if base.attach_ent ~= nil then
         add_hud_message("blue flag dropped")
      end
      base.attach_ent = nil
      base.dropped_return_frames = pm_flag_return_frames
      base.flip_image = false
   end,
   return_flag=function(base, was_captured)
      base.px = base.start_pos[1]
      base.py = base.start_pos[2]
      base.attach_ent = nil
      base.flip_image = false
      if was_captured then
         base.captures += 1
         if base.captures == pm_capturelimit then
            play_music(9)
            timing.session_end = time()
            title['in_ending'] = true
         else
            play_music(9)
            local ts = time_str(time() - timing.round_start)
            add_hud_message("blue flag captured in "..ts.."!")
            timing.round_start = time()
            printh("reset time to "..timing.round_start)
         end
      else
         play_music(0)
         local hatedisc_ent = find_ent_of_type(hatedisc)
         if hatedisc_ent ~= nil then
            hatedisc_ent.type.reset(hatedisc_ent)
         end
         add_hud_message("blue flag returned")
      end
   end,

}
add(types, blueflag)

slime = {
   tile = 32,
   invmass=0.8,
   spawn_count = 0,
   can_collide = true,
   verlet_clamp = true,   
   
   init=function(base)
      base.spr = slime.tile
      base.phys = mixin_copy(phys)
      base.emove = mixin_copy(emove)
      base.target = nil
      

      slime.spawn_count += 1
      base.frames_until_jump = pm_frames_between_jumps + (slime.spawn_count*5)
   end,
   tick=function(base)
      if base.target == nil then
         base.target = find_ent_of_type(blueflag)
      end
      
      local in_air = is_in_air_maponly(base)
      if in_air then
         base.emove.standing_on = ent_trace(base.px+4, base.py+9, ent_list)
         in_air = base.emove.standing_on == 0
      end

      if base.target.px < base.px then
         base.phys.force_accum_x -= pm_enemymoverate
      else
         base.phys.force_accum_x += pm_enemymoverate
      end

      if base.is_under_killfloor(base) then
         del_ent(base)
      end

      base.frames_until_jump -= 1
      if base.frames_until_jump < 0 and not in_air then
         if abs(base.py - base.target.py) > 8 then
            base.frames_until_jump = pm_frames_between_jumps
            base.phys.impulse_accum_y -= 4.5
            --base.phys.force_accum_y -= 6
         else
            base.frames_until_jump = pm_frames_between_jumps
         end
      end
      
      base.emove.apply_gravity(base)
      base.phys.integrate(base)
   end,
   on_touch = function(base, touch_ent)
      if touch_ent.type == player then
         touch_ent.type.on_damage(touch_ent, base)
      end
   end,
}
add(types, slime)

patrolbot = {
   tile = 19,
   can_collide = true,
   move_rate = 0.2,
   anim_rate = 20,
   init=function(base)
      base.spr = patrolbot.tile
      base.direction = 1
      base.dead = false
      base.spr_frames = patrolbot.anim_rate
   end,
   tick=function(base)
      if base.dead then return end
      -- can move to the right?
      local wish = {base.px + (base.direction * patrolbot.move_rate), base.py}
      local pts = tile_trace(wish[1], wish[2])

      local has_floor = 0
      for i=3,4 do
         local tile = pts[i][1]
         if fget(tile, collision) then
            --rect(pts[i][2]+cam[1], pts[i][3]+cam[2], pts[i][2]+8+cam[1], pts[i][3]+8+cam[2], i+7)
            has_floor += 1
         end
      end

      local has_wall = 0
      for i=1,2 do
         local tile = pts[i][1]
         if fget(tile, collision) then
            --rect(pts[i][2]+cam[1], pts[i][3]+cam[2], pts[i][2]+8+cam[1], pts[i][3]+8+cam[2], i+7)
            has_wall += 1
         end
      end

      if has_floor <= 1 or has_wall >= 1 then
         base.direction *= -1
      end
      base.px = wish[1]

      base.spr_frames -= 1
      if base.spr_frames == 0 then
         if base.spr == 19 then base.spr = 20
         else base.spr = 19 end
         base.spr_frames = patrolbot.anim_rate
      end
   end,
   on_touch=function(base, touch_ent)
      if base.dead then return end
      if touch_ent.type == player then
         -- did the player stomp on it?
         if touch_ent.py+6 < base.py then
            touch_ent.phys.impulse_accum_y -= 2.0
            base.type.on_damage(base, touch_ent)
            shake.frames = 8
         else
            touch_ent.type.on_damage(touch_ent, base)
         end
      end
   end,
   on_damage=function(base, attacker_ent)
      -- death code here
      base.spr = 21
      base.dead = true
      sfx(28,3)
   end,
}
add(types, patrolbot)

hatedisc = {
   tile = 31,
   accel_rate = 0.015,
   invmass=0.995,
   sound_interval=120,
   
   can_collide = nil,
   init=function(base)
      base.spr = hatedisc.tile
      base.phys = mixin_copy(phys)
      base.phys.no_clip = true
      base.was_idle = true
      base.unleash_frames = 0
      base.sound_frames = 1
   end,
   tick=function(base)
      if base.blueflag_ent == nil then
         base.blueflag_ent = find_ent_of_type(blueflag)
      end

      -- idle frame
      if base.blueflag_ent.attach_ent == nil or
         base.blueflag_ent.captures != 1 then
         base.spr = 31
         base.was_idle = true
         return
      end

      if base.unleash_frames > 0 then
         base.unleash_frames -= 1
         base.spr = flr(rnd(100))
         music(-1)
         return
      end

      -- flag just got attached
      if base.was_idle then
         sfx(30,2)
         base.phys.reset(base)
         base.unleash_frames = 60*3
         shake.frames = base.unleash_frames
         base.was_idle = false
         return
      end
      
      base.spr = 15
      -- chase blue flag
      local target_ent = base.blueflag_ent
      local d = vec_sub({target_ent.px, target_ent.py}, {base.px, base.py})
      
      -- avoid magsq test which overflows if the flag is far away anyway
      local magsq = vec_dot(d,d)      
      if abs(d[1]) > 400 or abs(d[2]) > 400 or magsq < 0 then
         printh("escaped!")
         base.px = target_ent.px + 64
         base.type.init(base)
         return
      end
      
      local nd = vec_norm(d)
      base.phys.force_accum_x += nd[1] * hatedisc.accel_rate
      base.phys.force_accum_y += nd[2] * hatedisc.accel_rate
      base.phys.integrate(base)
      --vis_vec2({64, 64}, nd, 10, 11)

      local magsq = vec_dot(d,d)
      if magsq < 60 then
         local player = get_player(1)
         player.type.on_damage(player, base)
      end
      

      -- play sound at intervals
      base.sound_frames -= 1
      if base.sound_frames == 0 then
         base.sound_frames = hatedisc.sound_interval
         -- select sound based on distance
         local mag = sqrt(magsq)
         if mag < 28 then
            sfx(33,2)
         elseif mag < 60 then
            sfx(32,2)
         else
            sfx(31,2)
         end
      end
   end,
   reset=function(base)
      base.px = base.start_pos[1]
      base.py = base.start_pos[2]
      base.phys.reset(base)
      base.unleash_frames = 0
      base.was_idle = true
      base.sound_frames = hatedisc.sound_interval
   end,
   draw=function(base)
      local is_idle = base.spr == 31
      local flip = not is_idle and base.blueflag_ent.px < base.px
      
      -- draw orbit disc
      if not is_idle then
         local sprite = 30
         if flip then sprite = 47 end
         
         local x, y = 1,1
         x += (sin(time()*0.4)) * 6
         y += (cos(time()*0.4)) * 6
         spr(sprite, cam[1]+base.px+x, cam[2]+base.py+y)

         x, y = 1,1
         x += (sin(-time()*0.4)) * 6
         y += (cos(-time()*0.4)) * 6
         sprite = 47
         if flip then sprite = 30 end
         
         spr(sprite, cam[1]+base.px+x, cam[2]+base.py+y)
      end

      -- draw main
      spr(base.spr, base.px+cam[1], base.py+cam[2], 1, 1, flip, false)

   end,
}
add(types, hatedisc)

-- spikes, basically
-- they don't actually collide (removing the need for n-squared aabb tests)
-- the lowest killtouch in a level generates a killfloor which your entity
-- can detect with a simple boolean test
killtouch = {
   tile = 34,
   can_collide = false,
   init=function(base)
      base.spr = killtouch.tile
      base.py += 4
         if killfloor < base.py then
         killfloor = base.py+4
      end
   end,
}
add(types, killtouch)

grapple_hook = {
   tile = 57,
   can_collide = true,
   init=function(base)
      base.spr = grapple_hook.tile
   end,
}
add(types, grapple_hook)

-- the grapple coming out of the player
extended_grapple = {
   init=function(base)
      base.spr = 35

      -- find nearest hook
      -- perf: cache hooks in dense list
      local player = get_player(1)
      local best_hook = nil
      local best_hook_distsq = 32767
      for ent in all(ent_list) do
         if ent.type == grapple_hook then
            -- constrain best-match to screenspace aabb
            local box_min = {-cam[1], -cam[2]}
            local box_max = {-cam[1]+64, 127}
            if player.phys.vx > 0 then
               box_min[1] += 64
               box_max[1] += 64
            end
            
            --rect(box_min[1]+cam[1], box_min[2]+cam[2],
            --box_max[1]+cam[1], box_max[2]+cam[2], 9)

            if pt_in_aabb(box_min, box_max, {ent.px, ent.py}) then
               -- sort available grapple hooks by distance
               local distsq = vec_distsq({ent.px, ent.py},
                                         {base.px, base.py})
               if distsq < best_hook_distsq then
                  best_hook_distsq = distsq
                  best_hook = ent
               end
            end
         end
      end

      base.target_hook = best_hook
      base.extending_frames = 0
      -- 0=extending, 1=contracting
      base.state = 0

      base.grapple_origin = {player.px+4, player.py}

   end,
   tick=function(base)
      if base.target_hook == nil then return end
      --circ(base.target_hook.px+cam[1],
      --base.target_hook.py+cam[2], 16, 11)

      local player = get_player(1)
      -- handle extending
      if base.state == 0 then
         base.grapple_origin = {player.px, player.py}
         
         base.extending_frames += 1
         
         -- full length
         local p1 = base.grapple_origin
         local p2 = {base.target_hook.px + 4,
                     base.target_hook.py + 8}
         
         if p2[2] > p1[2] then p1[2] +=8 end
         
         -- length of grapple extension modified by time
         local delta = vec_sub(p2,p1)
         local n = vec_norm(delta)
         local p2_t = vec_mul(n, base.extending_frames * pm_grapplerate)
         p2_t = vec_add(p1,p2_t)

         -- test grapple endpoint for collision with hook point
         -- perf: cache hooks in dense list
         local ent_hit = ent_trace(p2_t[1], p2_t[2], ent_list)
         if ent_hit ~= nil and
            ent_hit.type == grapple_hook then
               base.state = 1
               sfx(22,3)
               -- snap to final location
               base.px = ent_hit.px + 4
               base.py = ent_hit.py + 8
         else
            -- store grapple endpoint in entity origin
            base.px, base.py = p2_t[1], p2_t[2]
         end

      elseif base.state == 1 then         
         base.grapple_origin = {player.px, player.py}
         local p1 = {base.px, base.py}   -- endpoint
         local p2 = {player.px, player.py}  -- player
         local delta = vec_sub(p1,p2)
         local n = vec_norm(delta)

         local player_distsq = vec_distsq({player.px+4, player.py}, {base.px+4, base.py})
         if player_distsq > 200 then
            local rate = 0.25
            player.phys.impulse_accum_x += n[1] * rate
            player.phys.impulse_accum_y += n[2] * rate
         end
      end
   end,
   draw=function(base)
      if base.target_hook == nil then return end      
      local player = get_player(1)
      x = 0
      if player.phys.vx > 0 then x = 7 end
      
      line(base.grapple_origin[1]+cam[1]+x,
           base.grapple_origin[2]+cam[2],
           base.px+cam[1], base.py+cam[2], 13)
      

   end,
}
add(types, extended_grapple)

health = {
   tile = 13,
   init=function(base)
      base.spr = health.tile
      base.enabled = true
   end,
   tick=function(base)
      if not base.enabled then return false end
      local player = get_player(1)
      if player.is_spawned and player.health < 1 and ent_in_ent(base, player) then
         sfx(22,3)
         player.health = max(player.health, 1)
         base.enabled = false
      end
   end,
   draw=function(base)
      if not base.enabled then return false end
      spr(base.spr, base.px+cam[1], base.py+cam[2])
   end,
}
add(types, health)

-- a physical particle that drops after starting at a certain location.  cycles through
-- colors over lifetime, drawing a single pixel.
phys_particle = {
   invmass = 0.97,
   init=function(base)
      -- these can be configured
      base.lifetime_frames = 150
      base.colors = {7,12,6,6,13,13,5,5}
      
      base.phys = mixin_copy(phys)
      base.particle_lifetime = base.lifetime_frames

      base.step = flr(base.particle_lifetime / #base.colors)
      base.color_frames = base.step
      base.color_i = 1
   end,

   tick=function(base)
      if base.lifetime_frames == 0 then
         del_ent(base)
         return
      end
      base.lifetime_frames -= 1
      
      base.phys.force_accum_y += pm_gravity
      base.phys.integrate(base)
   end,
   draw=function(base)
      base.color_frames -= 1
      if base.color_frames == 0 then
         base.color_frames = base.step
         base.color_i += 1
         if base.color_i > #base.colors then base.color_i = #base.colors end
      end
      
      pset(base.px+cam[1]+4, base.py+cam[2]+8, base.colors[base.color_i])
   end,
}
add(types, drop_particle)


env_anim = {
   tile=44,
   idle_frames = 20,
   action_frames = 10,
   
   init=function(base)
      base.on_spr = base.type.tile
      base.off_spr = 43
      
      base.idle_remaining = (base.px)+1
      base.action_remaining = 0
      base.spr = base.off_spr
      
   end,
   tick=function(base)
      if base.idle_remaining > 0 then
         base.idle_remaining -= 1
         if base.idle_remaining == 0 then
            base.spr = base.on_spr
            base.action_remaining = base.type.action_frames
         end
         
      elseif base.action_remaining > 0 then
         base.action_remaining -= 1
         if base.action_remaining == 0 then
            base.spr = base.off_spr
            base.idle_remaining = base.type.idle_frames
         end
      end

   end,
}
add(types, env_anim)


--
-- logique
--
function init_worldents()
   for tx=0,128 do
      for ty=0,50 do
         local tile = mget(tx,ty)
         for i=1,#types do
            if types[i].tile == tile then
               ent = init_ent(types[i], tx*8, ty*8)
               
               -- all entities created at world init are preserved on restart
               ent.preserve_on_restart = true
               -- entity handles drawing this type now
               mset(tx,ty,0)
            end
         end
      end
   end
end

function draw_hud()
   local player = get_player(1)
   -- health   
   if player.health == 1 and player.is_spawned then
      spr(13, 2, 5)
   else
      spr(12, 2, 5)
   end

   -- flag locator
   if blueflag_ent == nil then
      blueflag_ent = find_ent_of_type(blueflag)
   end
   if blueflag_ent.px > player.px + 64+8 then
      spr(14, 118, blueflag_ent.py, 1, 1, true)
   elseif blueflag_ent.px < player.px - (64+8) then
      spr(14, 2, blueflag_ent.py)
   end

   -- message
   if cur_message ~= nil then
      cur_message.draw(cur_message)
   end

   -- draw time
   local round_time = time() - timing.round_start
   local ts = time_str(round_time)
   print(ts, 15, 7, 6)

   -- draw captures
   print(blueflag_ent.captures..' of '..pm_capturelimit, 13, 120, 6)
   spr(17, 2, 118)
end

hud_message = {
   flash_rate = 30,
   init=function(base, msg)
      base.msg = msg
      base.frames_remaining = 60*5
      base.flash_frames = hud_message.flash_rate
      base.color = 1
   end,
   draw=function(base)
      local w = #base.msg * 4
      local x = 64-(w/2)

      -- bg
      base.flash_frames -= 1
      if base.flash_frames == 0 then
         base.flash_frames = hud_message.flash_rate
         if base.color == 1 then
            base.color = 12
            base.flash_frames = 3
         else
            base.color = 1
         end
      end
      rectfill(x-6, 108, x+w+2, 116, base.color)

      -- body
      local color = 12
      if base.color == 12 then color = 7 end
      print(base.msg, x, 110, color)
      local xleft = 60-(w/2)
      rect(xleft, 111, xleft+1, 112, 7)
      local xright = 64+(w/2)
      rect(xright, 111, xright+1, 112, 7)
      
      base.frames_remaining -= 1
      if base.frames_remaining == 0 then
         cur_message = nil
         base = nil
         return
      end
   end,
}

function play_music(seq)
   if dev then return end
   if seq == cur_music then return end
   music(seq)
end

function do_title()
   printh("do_title")
   play_music(0)
   title['in_title'] = true
   title['starting'] = false
   title['in_ending'] = false   
end

function start_session()
   printh("start_session")
   timing.session_start = time()
   timing.round_start = time()
   title = {}

   -- sadly, we can't destroy and re-create all of the entities because
   -- we deleted the tiles they depend on at startup
   local player = get_player(1)
   player.lives_frames = 0

   -- delete entities not preserved on restart
   for i = #ent_list,1,-1 do
      local ent = ent_list[i]
      if ent.preserve_on_restart == false then
         del_ent(ent)
      end
   end

   -- reset all entity positions and call init otherwise
   for ent in all(ent_list) do
      ent.px = ent.start_pos[1]
      ent.py = ent.start_pos[2]
      if ent.phys ~= nil then
         ent.phys.reset(ent)
      end
      ent.type.init(ent)
   end
   player.type.spawn(player)

   local flag = find_ent_of_type(blueflag)
   flag.captures = 0
end

function _init()
   printh("=============================================")
   local player = init_ent(player, 10, 40)
   player.preserve_on_restart = true
   init_worldents()
   
   do_title()
end

function _update60()
   if dev then cls() end

   local player = get_player(1)
   if player.lives == -1 and not title['in_title'] then
      do_title()
      return
   end


   if title['in_title'] then
      if btnp(4) or btnp(5) and title['starting'] == false then
         sfx(27,3)
         title['starting'] = true
         if not dev then
            title['start_frames'] = 60
         else
            title['start_frames'] = 1
         end
      end
      return
   end

   if title['in_ending'] then
      if btnp(4) or btnp(5) then
         sfx(27,3)
         do_title()
      end
   end
   
   tick_count +=1 
   
   for ent in all(ent_list) do
      if ent.type.tick ~= nil then
         ent.type.tick(ent)
      end
   end

   exec_touch_events()
end

function _draw()
   if not dev then cls() end

   if title['in_title'] then
      map(112,50)
      print_centerx("capture the flag", 20, 7)
      print_centerx("gamepad or x+c+arrows", 66, 9)
      print_centerx("capture the flag twice to win", 86, 7)
      print_centerx("by michael labbe", 103, 5)      
      print_centerx("(c) 2016-2018 frogtoss games, inc", 110, 5)

      if title['starting'] then
         title['start_frames'] -= 1
         if title['start_frames'] == 0 then
            start_session()
         end
      end
      return
   end

   if title['in_ending'] then
      map(96,50)
      print_centerx("red team wins the match!", 64, 8)
      local ts = time_str(timing.session_end - timing.session_start)
      print_centerx("your total time is "..ts, 72, 7)
      print_centerx("x+c", 80, 9)
      return
   end
   
   -- camera logic here
   cam[1] = min(-get_player(1).px + 64, 0)
   cam[2] = 0
   
   if shake.frames > 0 then
      shake.frames -= 1
      camera(-1+rnd(2),-1+rnd(2)) 
   else
      camera()
   end
   
   map(0,0,cam[1],cam[2])

   for ent in all(ent_list) do
      if ent.type.draw ~= nil then
         ent.type.draw(ent)
      else
         spr(ent.spr, flr(ent.px+cam[1]),
             flr(ent.py+cam[2]))
      end
   end

   draw_hud()

   -- debug vis
   if dev then
      line(0, killfloor, 128, killfloor, 11)
   
      -- print stats
      print("mem: " .. stat(0), 80, 10, 15)
      print("cpu: " .. stat(1), 80, 20, 15)
   end
end

__gfx__
000000000009990000099000000999000009990000000000dddddddd66ddddd6000000000c0000c00800008001cccc100000000000000000000cccc000229900
00000000009999900099999000999990009999900000000066ddddd6666ddd66000000000cddddc008222280cccccccc007707700077077000cddc000299aa90
007007000999449009994490099944909999449000900900666ddd666666d666000000000cccccc008888880cc0cc0cc0700700707ee78870cddc0002999aaa9
000770000994ff000994ff009994ff009994ff0000099000666ddd66666ddd66000000000cccccc008888880cc8cc8cc0700000607eee886cddc00002089a809
000770000990e2e00990e2259900e2ef0000e2ef0009900066ddddd666ddddd6000000000ccccdc008888280dccccccd0700000607ee8886cddc00002999aaa9
00700700000e2e00099e2e5000002e2000002e2000900900666ddd66666ddd66000000000ccccdc0088882800ddccdd000700060007e88600cddc0002999aaa9
000000000002e2000002e20000dce20000dce200000000006666d6666666d666000000000cccdcc0088888800d0dd0d0000706000007860000cddc00029aaa90
00000000000c0c000000c00000000c0000000c0000000000666ddd66666ddd66000000000cccccc0088888800d0500d00000600000006000000cccc000299900
0000000000000000000000000044440000000000000000001111111111111111111111110cccccc0088888800d0050d07ffffff5feeeeee50020000000dddd00
80088800c00ccc0000000000044444400044440000000000111ddddd11111111111111110cdcccc0088888800d0500d0f9999994e8888882028200000d555550
88708880cc77ccc0000000000504405004444440004444001111d66611111111111111110cd77cc0088078800d0050d0f9244294e852228228e82000d5555555
88078880cc070cc00000000005555550050440500444444011dd666611111111111111110cc70dc0088708800d0000d0f9400f94e820058202820000d5055055
088800d00ccc00d0000000000955550005555550550440551111d66611111111111111110cccccc0088888800d0000d0f9400794e820058200200000d5555555
000000d0000000d0000000009900900000555590555555c5111ddddd555055551111111100cccc00008888000d0000d0f92f7f94e825558200000000d5555555
000000d0000000d0000000000000990000900099055555501ddddddd0005000011111111000000000000000000000000f9999994e8888882000000000d555550
000000d0000000d00000000000000000099000000000000011111111000500001111111100000000000000000000000054444444522222220000000000555500
00000000000000000000000000000000994400000009449922222222222222222222222200050000000000000000000000000000d66666d005d6dd5000100000
0300000300000000000000000000000022224000009222228822222222222222222222220005000000000000000000000000000075d5d5d505d6dd5001c10000
030000033000003000020002000000002222290004224222882822222222222222222222055055550000000000000000002220006d5d5d5505d6dd501c6c1000
0303330330333030080508050000000022422900042222228882282222222222222222225000005000000000005550000288820065d5d5d505d6dd5001c10000
003b3b3033b3b33006050605000000002222224092422222ee888882222222222222222250000050000000000055500002e882006d5d5d5505d6dd5000100000
033b3b3333b3b33006050605000000002222224042222222e8e8882255505555222222225000005000000000000000000022200065d5d5d505d6dd5000000000
03333333333333305655565500000000222242244222222282882222000500002222222205555500000000000000000000000000dd5d5d5505d6dd5000000000
003000300300030066656665000000002222222442222222222222220005000022222222000500000000000000000000000000000555555505d6dd5000000000
dddddddd55555555555555005550055500000000000000000940049000555555455555550009950000000000000000006cccccc5c6ccccc500000000033b33b5
5677777ddddddddddddddd50ddd55ddd00000000000000099224944905dddddd49444445000599505555555555555500cdddddd16dddddd100000000053b03b0
5667777ddddddddddddddd50dddddddd00000000944004994222222205dddddd4994444500005995ccccccccccccccd0cd5115d1cdddddd100000000003b03b0
5666777d66666666666666d0666666660000000022244224222222240d666666499944450000059977777777777777f0cd100cd1cdddddd100000000000b00b0
5666677d777777777777776077777777000000002242222222422222067777774999944559000099eeeeeeeeeeeeee20cd1006d1cdddddd1000b000000000000
5666667d66666666666666d0666dd6660000000022222222222222220d66666649999945990000992222222222222210cd5c6cd1cdddddd1000b003000000000
5666666d66666666666666d066d55d660000000022222422222224220d66666649999995999999951111111111111100cdddddd1cdddddd5003b303500000000
5555555555555555555555005550055500000000222222222222222200555555444444440999a99000000000000000005111111151111151053b353500000000
000000000f9999500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000f995000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000
00000000000f95000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000aacc000000000
00000000000f9500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000aaa00000099cccc0000000
00000000000f95000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022a900000d99ccccdd00000
00000000000f95000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002288899000099cccccccdd000
00000000000f95000000000000000000000000000000000000000000000000000000000000000000000000000000000000002228888889200d99cccccccccd00
00000000000f9500000000000000000000000000000000000000000000000000000000000000000000000000000000000088888888888992099cccccccccccc0
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000888888888888899099ccccccccccccc
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008888888888888889999ddcccccdccccc
006600000006000000000000000600000000000000000000000000000000000000000000000000000000000000000000088888888888888899000dcccddccccc
0766606007660000000600000000000000000000000000000000000000000000000000000000000000000000000000000888888888888820499000dddddcccc0
066600600666660000666000060000600000000000000000000000000000000000000000000000000000000000000000008888222888820094990000ddddccc0
00006660006666000006000000000000000000000000000000000000000000000000000000000000000000000000000000088882228820099009900000ddcc00
066067000600670000000000000600000000000000000000000000000000000000000000000000000000000000000000000888822222000990009900000ddd00
0760000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000882222000099000009900000dd00
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002220000000990000009900000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009900000000990000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009900000000099000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000099000000000009900000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000099000000000009900000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000055555555555550000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000055555555550000000555555555
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555000000000055555555
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000b20000000000000000000000000000e000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c4d4e4f4000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c5d5e5f5000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c6d6e6f6000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c7d7e7f7000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000b200000000000000000000000000000000
__gff__
0000000000000101000000000000000000000000000000000000000001010000000000000101000000000101010101000101010100010101010001010101000000010003000200000000000000000000000000000000000000000000000000000001000100010001000000010001000100000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__map__
2e2d2d2d2d2d2d3d1c3d2d2d3d1c3d2d2d2d2d2d3d1c3d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d3d3d3d3d2d2d2d3d3d3d2d2d3d3d3d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d392d2d2d2d2d2d2d412d2d2d2d412d2d2d2d2d2d2d2e000000000000000000000000000000000000000000000000000000
2e2c2c2c2c2c2c2c4100000000413731313131313241000000000000000000000000000000002d3d3d1c3d2d2d003d3d3d00003c1c3c000000000000000000000000000000000000000000000000000000000000000000390000000039000000000000002e000000000000000000000000000000000000000000000000000000
2e0000282800000039000000003900003d3d3d0000392929000000133e00000d0000000000002d3d1c3d3d2d0000003d2929293d413d00000000000000000029181818292929000000000000000000000000000000000000000000000000001f000000002e000000000000000000000000000000000000000000000000000000
2e292926282900000000000000000000002d0000002929290000373131313332000000000000392d2d2d2d2d0029003d2929290039000000000000000000002918181629292900000000003d3d3c3d0000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000
2e292928282900000000000000000000003800000000000000000000000000000000000000002d000000001c0029001c0000292900000000002929293d3c3d2918181829000000001300000000003f0029181829000900000009000000292900000011002e000000000000000000000000000000000000000000000000000000
2e002927272900000000000000000000002d00000000003e00000029262829000000000000000000292900410000004100000000000000000000000000000029171717290000003d3c3d00000000290029181629001900000019000000292900003030302e000000000000000000000000000000000000000000000000000000
2e0000000000300000000000000000000038000000001d2d1d00002928282900000000000000380000290039000000390000000000000000130030000000000000000000000000003000000000292900291818290000000000000000382929292d18182d2e000000000000000000000000000000000000000000000000000000
2e00000000002e292900000000002929002d00000000292900000029272729000000000000002d00000000000000000000000000000030303030303030303000000000003d3c000000000000002929002917172900000000000000003d0000291717173d2e000000000000000000000000000000000000000000000000000000
2e00000000002e29292d0013002d2929003800000000292900000000000013000000000000002d000000000000000000000000000000003f000000000030390000000000003000000029000000000000000000000030003000300000300013000000003c2e000000000000000000000000000000000000000000000000000000
2e00100000002e00002d2d2d2d2d0000002d00000000000000003733313131320000000000002d0000000000000000000000000000000000002929000030000000003c3d003f00292929002d3a3a2d00000000000000003f000000003d3a3a3a3a3a3a3b2e000000000000000000000000000000000000000000000000000000
2e30303000002e0000002c2c2c000000003800000000000000000000003f00000000000000253624000000000029292929292929000000130000000d003000000000300000292929292900000000000000000000000000000000000030000000000000002e000000000000000000000000000000000000000000000000000000
2e28282824002e000000000000000000003600000000000800000000000000000000000000282828000000000000000000000000000025363535353536363624000000000000000000000000000000000000000000130000130000003d000000000000002e000000000000000000000000000000000000000000000000000000
2e28282828362e3622222222222222222228222222222222222222222536363635242222222828282222222222222222222222222222282828282828282828282222222222222222222222222222222222222206060606060606060606000029292900002e000000000000000000000000000000000000000000000000000000
2e28282828282e2800000000000000000028000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007070707070707070707000029292900002e000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__sfx__
00010000120701307014070150701b0701b0701c0701d0701e0701e07000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000200017000000001700000004170000000007000000001700117000170000000407000000000700000005070000000507000000061700000005070000000717009170051700000007070000000507000000
001000000c1731a00000000000003c6730000000000000000c173000000c173000003c6730000000000000000c17300000000000c1733c6730000000000000000c1730000000000000000c173000003b67400000
001000000c1700c1703b606000000c1700e17010170101701317100000101700000010170000001a1710000018172181720000000000000000000000000000000000000000000000000000000000000000000000
00100000181701817000000000001a170000001c1701f17021170211711817100000000000000000000000001c1701f170211702117118171000001f1711f171000000000021170000001c1711c1711c1711c171
001000001a1701a1701c000000001f1711f17100000000001817218172181720c1722400026000240000000017102171021710217102000000000000000000001717217172131721717217172000000000000000
0010000000170001000c0700c00000170001700c0700c07000170001000c0700c00000170001700c0700c07000170001000c0700c00000170001700c0700c07000170001000c0700c00000170001700c0700c070
001000000c1731a0000c173000003c673000000c173000003c6733b6340c173000000c1731a0000c173000003c673000000c173000003c6733b6040c173000000c1731a0000c173000003c673000000c17300000
001000000c1700c1701a1001c1000c1700e1702110124100131701117018100181000e170211000e1701f1000c170231000c1701c000151701517018000180001f1701f170180001c1711c171180001a1711a171
001000001107000100110700c00011170111701107011070111700010011070000000e170001000e0700c0000e1700e1700e0700e0700e170001000e070000001117000100110700c00011170111701107011070
001000000023000000002300000004230000000023000000002300123000230000000423000000002300000005230000000523000000062300000005230000000723009230052300000007230000000523000000
0012000000170001700000000000031700317002170021700017000170000000000001170011700000010100001700017000000000000d1000d10000000000000417004170000000000003170031700000000000
001200000023000230000000000003230032300223002230002300023000000000000123001230000001010000230002300000000000000000000000000000000423004230000000000003230032300020000000
011200001f27021270222702227022260222502224022230222302223022230222303c604000003c605000003c604000003c605000003c604000003c605000003c604000003c605000003c604000003c60500000
011200000c103000000a2700a2700a2600a2500a2400a2300a2300a2200a2100a2100c1030000000000000003c6030000000000000000c1030000000000000000c1030000000000000003c603000000000000000
010f00000c4700c2700c4700c2700b4700b2700b4700b270074700727007470072700447005270052700527205272052000540100000000000000000000000000000000000000000000000000000000000000000
011100000637000000063700000006370000000637007370000000000000000000000930000000093000000009370000000937000000093700000007370063700730000000000000000000000000000000000000
001100000747000000074700000013470000000737007470134701347000000000001347000000063000000006470000000647000000124700000006470064701147011470114711147110475063000000000000
011100001e5701d570185001c570195701d5001a4001c4001d4001a300185701b5701c5701d5701d2001a1001c1001d1001a7001c7001d7001c600000001c600000001d6001d5701c5701b570185700000000000
001100001f5721f5721f5721f57200000000000000000000000000000000000000001f5701f5701f572000001e5721e5721e5721e5721e5721e5721e57200000000000000000000000001c5701a5700000000000
001100000c173000000c173000000000000000000000000000000000003c673000000000000000000000c1030c173000000c173000000000000000000000000000000000003c6730c10300000000000000000000
001100000c1733c6040c1733c6043c6733c6040c173000000c1730000000000000003c67300000000000c1730c173000000c173000003c673000000c173000000c173000003c673000003c6533c6533c6533c653
00010000250702507025070290702e070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000100002b07025070220701f07020070200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00020000231701f1701e1701917018170205701a57018570165701117008170135701c570175701557014570105700f5700817013570125700f5700d57009170000000f1700e1700e1700e170161701a17000000
00020000105701057010570105701057010570105701057008500085000a5700a5700a5700a5700a5700a5700a5700a570085001e500055700557005570055700557005570055700000000000000000000000000
000200000e7700e7700f7700f770107702777010770307700f770277701c7700e7701c770267700d7701c770267701b7700c770267701277012770147701577017770197701a7701c7701e7701f7702477029770
01050000340713407134071320723207232072320712d70128500285002750027500275000c3000d3000f3001030013300275001d3001d300283002e30033300000000000000000000000000000000000001a300
000100001a2000a2700d2701124015240182401c2501f2501c2502225023250232501b250122600f2600f270000001c3700000000000000000000000000000000000000000000000000000000000000000000000
00010000000002c070240701c07017070120700c0700a070090700000008070070700707009070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000a00000c6500c6500c660184601546015460134601046010460096600966008660076502e05005150061501c6501d6501d6501b4501645015450174501445013450031500b6500b6500b660160601307013070
000500000947009470094700947000000000000000005470054700547005470043000430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000500001247012470124701247000000000000000000000114701147011470114701030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000500001947019470194701947019400000000000018470184701847018470000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__music__
01 0102434a
00 01020344
00 01020344
00 01020444
00 01020544
00 06070844
00 09070344
00 06070844
02 06070444
02 41420d0e
02 404c4d4e
00 0f414243
01 10141243
02 11151343
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243
00 41414243

