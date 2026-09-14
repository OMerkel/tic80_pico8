-- title:   runner
-- author:  Oliver
-- desc:    A classic arcade runner with traps, guards, and treasure.
-- site:    https://github.com/OMerkel/tic80_pico8
-- license: MIT License
-- version: 0.2
-- script:  lua

t=0

-- tuning constants
STEP_TICKS=3        -- frames per movement step (controls runner speed, and the guard scheduler's cadence)
GUARD_STEP_TICKS=6  -- only used to size the post-escape grace period; guard speed comes from MOVE_POLICY
HOLE_LIFETIME=360    -- ticks until a dug hole refills itself
GUARD_TRAP_ESCAPE=150 -- ticks a trapped guard needs to climb back out
GUARD_BOX_CARRY_TICKS=600 -- base time a guard carries a box
GUARD_BOX_CARRY_RANDOM=360 -- maximum random extra carry time
LEVEL_COMPLETE_WAIT=360 -- 6 seconds at 60 TIC-80 frames per second
LIVES_START=3
SCREEN_HEIGHT=136

-- guard AI flags / game options
guards_pit_aware=false
draw_carried_box=true

-- classic Lode Runner move policy, indexed by guard count then cycle position:
-- the total step budget grows sublinearly, so a crowd of guards is individually slower than a lone one
MOVE_POLICY={
 {0,0,0,0,0,0},
 {0,1,1,0,1,1},
 {1,1,1,1,1,1},
 {1,2,1,1,2,1},
 {1,2,2,1,2,2},
 {2,2,2,2,2,2},
 {2,2,3,2,2,3},
 {2,3,3,2,3,3},
 {3,3,3,3,3,3},
 {3,3,4,3,3,4},
 {3,4,4,3,4,4},
 {4,4,4,4,4,4}
}
MOVE_CYCLE=6
move_offset=0
move_id=0

-- game state
current_level=1
boxes_remaining=0
ladders_revealed=false
level_complete=false
level_complete_timer=0
final_level_complete=false
game_over=false
lives=LIVES_START
holes={} -- key "tx,ty" -> {tx,ty,timer,orig,guard}

level_data = {
{{
"                        h ",
"                        h ",
" $               $ -----h ",
"###################     h "
},
{x=40,y=8,spawn_x=40,spawn_y=8,dir=1,falling=false,idx=0,step=STEP_TICKS},
{}},

{{
"                        h ",
" $                 -----h ",
"################H##     h ",
"                H     $ h ",
"         -------HHH   $ h ",
" H#####    ---  HH H    h ",
" H              H  #### h ",
" H              H  #### h ",
" H              H    $  h ",
" H              H   $   h ",
"=========================="
},
{x=40,y=8,spawn_x=40,spawn_y=8,dir=1,falling=false,idx=0,step=STEP_TICKS},
{
 {x=4,y=56,spawn_x=4,spawn_y=56,dir=0,falling=false,idx=0,state="run",trapped_timer=0,tx=0,ty=0,step=GUARD_STEP_TICKS,carrying=false,carry_timer=0},
 {x=196,y=56,spawn_x=196,spawn_y=56,dir=1,falling=false,idx=0,state="run",trapped_timer=0,tx=0,ty=0,step=GUARD_STEP_TICKS,carrying=false,carry_timer=0},
}},

{{
"                  h         ",
"    $             h         ",
"#######H#######   h         ",
"       H----------h    $    ",
"       H    ##H   #######H##",
"       H    ##H          H  ",
"       H    ##H       $  H  ",
"##H#####    ########H#######",
"  H                 H       ",
"  H                 H       ",
"#########H##########H       ",
"         H          H       ",
"       $ H----------H   $   ",
"    H######         #######H",
"    H            $         H",
"############################"
},
{x=112,y=112,spawn_x=112,spawn_y=112,dir=1,falling=false,idx=0,step=STEP_TICKS},
{
 {x=40,y=48,spawn_x=40,spawn_y=48,dir=0,falling=false,idx=0,state="run",trapped_timer=0,tx=0,ty=0,step=GUARD_STEP_TICKS,carrying=false,carry_timer=0},
 {x=184,y=48,spawn_x=184,spawn_y=48,dir=0,falling=false,idx=0,state="run",trapped_timer=0,tx=0,ty=0,step=GUARD_STEP_TICKS,carrying=false,carry_timer=0},
 {x=120,y=72,spawn_x=120,spawn_y=72,dir=0,falling=false,idx=0,state="run",trapped_timer=0,tx=0,ty=0,step=GUARD_STEP_TICKS,carrying=false,carry_timer=0}
}}

}

level = level_data[current_level][1]

spr_box=1 -- $
spr_brick=2 -- # (digging allowed when free from top)
spr_floor=3 -- = (solid ground, no digging)
spr_ladder=4 -- H
spr_ladder_top=5 -- h (hidden until all boxes collected)
spr_bar=6 -- -

spr_guard_run=16 -- 16,17,18
spr_guard_hang=19 -- 19,20,21
spr_guard_climb=22 -- 22,23
spr_guard_fall=24 -- 24
-- spr_guard_idle=25 -- 25,26
-- spr_guard_trapped=25 -- 25
spr_runner_run=32 -- 32,33,34
spr_runner_hang=35 -- 35,36,37
spr_runner_climb=38 -- 38,39
spr_runner_fall=40 -- 40

-- entities
runner=level_data[current_level][2]
guards=level_data[current_level][3]

level_w=0
level_h=0

function set_level_bounds()
 level_h=#level
 level_w=0
 for ly=1,level_h do
  local n=level[ly]:len()
  if n>level_w then level_w=n end
 end
end

function load_level(level_index)
 current_level=level_index
 level=level_data[current_level][1]
 runner=level_data[current_level][2]
 guards=level_data[current_level][3]
 set_level_bounds()
 move_offset=0
 move_id=0
 boxes_remaining=count_boxes()
 ladders_revealed=false
 level_complete=false
 level_complete_timer=0
 holes={}
end

-- level helpers
function tile_xy(tx,ty)
 if ty<1 or ty>#level then return " " end
 local row=level[ty]
 if tx<1 or tx>row:len() then return " " end
 return row:sub(tx,tx)
end

function set_tile_xy(tx,ty,ch)
 if ty<1 or ty>#level then return end
 local row=level[ty]
 if tx<1 or tx>row:len() then return end
 level[ty]=row:sub(1,tx-1)..ch..row:sub(tx+1)
end

function tile_char_at_pixel(px,py)
 local tx=px//8+1
 local ty=py//8+1
 return tile_xy(tx,ty),tx,ty
end

function is_visible_ladder_char(c)
 return c=="H" or (c=="h" and ladders_revealed)
end

function is_solid(c)
 return c=="#" or c=="="
end

function count_boxes()
 local c=0
 for ly=1,#level do
  local row=level[ly]
  for lx=1,row:len() do
   if row:sub(lx,lx)=="$" then c=c+1 end
  end
 end
 return c
end

-- returns tile info for an 8x8 entity whose top-left corner is at (x,y)
function get_context(x,y)
 local cur,cur_tx,cur_ty=tile_char_at_pixel(x+4,y+4)
 local below,below_tx,below_ty=tile_char_at_pixel(x+4,y+8)
 return cur,cur_tx,cur_ty,below,below_tx,below_ty
end

-- a trapped guard's tile acts as safe, walkable ground for anyone standing on it
function guard_support_at(tx,ty)
 for _,g in ipairs(guards) do
  if g.state=="trapped" and g.tx==tx and g.ty==ty then return true end
 end
 return false
end

-- shared physics: horizontal movement blocked by bricks/floor, disabled while falling
function try_move_horizontal(e,left,right)
 if e.falling then return end
 if not e.ready then return end
 if left then
  local new_x=e.x-2
  local edge=tile_char_at_pixel(new_x,e.y+4)
  if not is_solid(edge) then
   e.x=new_x
   e.dir=1
  end
 elseif right then
  local new_x=e.x+2
  local edge=tile_char_at_pixel(new_x+7,e.y+4)
  if not is_solid(edge) then
   e.x=new_x
   e.dir=0
  end
 end
end

-- shared physics: ladder climbing and bar-drop, with flush snapping onto tile boundaries
function try_vertical_move(e,up,down)
 if not e.ready then return false end
 local cur,cur_tx,cur_ty,below,below_tx,below_ty=get_context(e.x,e.y)
 local on_ladder=is_visible_ladder_char(cur)
 local above_ladder=is_visible_ladder_char(below)
 local on_bar=(cur=="-")
 local moved=false

 if up and on_ladder then
  local new_y=e.y-2
  local exit_char,_,exit_ty=tile_char_at_pixel(e.x+4,new_y+4)
  if not is_solid(exit_char) then
   e.x=8*(cur_tx-1) -- snap onto the ladder's column when climbing starts
   e.y=new_y
   e.falling=false
   moved=true
   -- snap flush to the tile above once we've climbed past the top of the ladder
   if not is_visible_ladder_char(exit_char) then
    e.y=8*(exit_ty-1)
   end
  end
 end

 if down then
  -- at the foot of a ladder the column snap would pin the entity in place, so refuse the step entirely
  local blocked_below=is_solid(below) and e.y%8==0
  if (on_ladder or above_ladder) and not blocked_below then
   e.x=8*((on_ladder and cur_tx or below_tx)-1) -- snap onto the ladder's column when climbing starts
   e.y=e.y+2
   e.falling=false
   moved=true
   -- snap flush onto solid ground once we've climbed past the bottom of the ladder
   local land_char,_,land_ty=tile_char_at_pixel(e.x+4,e.y+8)
   if land_char=="#" or land_char=="=" then
    e.y=8*(land_ty-2)
   end
  elseif on_bar then
   e.falling=true
  end
 end

 return moved
end

-- shared physics: gravity, bar hanging and landing snap
function apply_gravity(e,moved_vert,down_pressed)
 -- brief immunity right after climbing out of a hole, so it isn't yanked straight back in
 if e.grace and e.grace>0 then
  e.grace=e.grace-1
  e.falling=false
  return
 end
 local cur,cur_tx,cur_ty,below,below_tx,below_ty=get_context(e.x,e.y)
 local on_bar=(cur=="-")
 local on_ladder=is_visible_ladder_char(cur)
 local support=is_solid(below) or is_visible_ladder_char(below) or guard_support_at(below_tx,below_ty)

 if on_bar and not down_pressed then
  e.falling=false
 else
  if not support and not on_ladder and not moved_vert then
   e.falling=true
  elseif support then
   e.falling=false
  end
 end

 if e.falling and e.ready then
  e.y=e.y+2
 end

 -- stop fall when reaching a bar (but not if dropping through one on purpose)
 cur,cur_tx,cur_ty=tile_char_at_pixel(e.x+4,e.y+4)
 if cur=="-" and not down_pressed then
  e.falling=false
  e.y=8*(cur_ty-1)
 end
 -- stop fall when supported by solid ground, a ladder, or a trapped guard's back
 below,below_tx,below_ty=tile_char_at_pixel(e.x+4,e.y+8)
 if e.falling and (is_solid(below) or is_visible_ladder_char(below) or guard_support_at(below_tx,below_ty)) then
  local target_y=8*(below_ty-2)
  if e.y>target_y then e.y=target_y end
  e.falling=false
 end
end

-- digging: opens a temporary hole in the brick beside the runner, one row below its feet
function try_dig(dir)
 local cur,cur_tx,_,_,_,below_ty=get_context(runner.x,runner.y)
 local target_tx=cur_tx+dir
 local ch=tile_xy(target_tx,below_ty)
 -- blocked if solid ground sits on top of the target brick (unless that spot is already an open pit)
 local above_ch=tile_xy(target_tx,below_ty-1)
 if ch=="#" and not is_solid(above_ch) then
  local key=target_tx..","..below_ty
  if not holes[key] then
   set_tile_xy(target_tx,below_ty," ")
   holes[key]={tx=target_tx,ty=below_ty,timer=HOLE_LIFETIME,orig="#",guard=nil}
  end
 end
end

function update_holes()
 for key,h in pairs(holes) do
  h.timer=h.timer-1
  if h.timer<=0 then
   local runner_cur,runner_tx,runner_ty=tile_char_at_pixel(runner.x+4,runner.y+4)
   if runner_tx==h.tx and runner_ty==h.ty then
    lose_life()
    return
   end
   if h.guard then respawn_guard(h.guard) end
  if tile_xy(h.tx,h.ty)~="$" then set_tile_xy(h.tx,h.ty,h.orig) end
   holes[key]=nil
  end
 end
end

function close_all_holes()
 for _,h in pairs(holes) do
  if tile_xy(h.tx,h.ty)~="$" then set_tile_xy(h.tx,h.ty,h.orig) end
  if h.guard then h.guard.state="run" end
 end
 holes={}
end

function respawn_guard(g)
 if g.carrying then
  local _,tx,ty=tile_char_at_pixel(g.x+4,g.y+4)
  set_tile_xy(tx,ty,"$")
 end
 g.x=g.spawn_x
 g.y=g.spawn_y
 g.falling=false
 g.state="run"
 g.trapped_timer=0
 g.carrying=false
 g.carry_timer=0
end

function check_offscreen_falls()
 if runner.y>SCREEN_HEIGHT then lose_life() end
 for _,g in ipairs(guards) do
  if g.y>SCREEN_HEIGHT then respawn_guard(g) end
 end
end

-- a guard standing over a hole tile gets stuck until it climbs out or the hole refills
function check_trap(g)
 if g.state=="trapped" then return end
 local cur,cur_tx,cur_ty=tile_char_at_pixel(g.x+4,g.y+4)
 local hole=holes[cur_tx..","..cur_ty]
 if hole then
  g.state="trapped"
  g.falling=false
  g.trapped_timer=GUARD_TRAP_ESCAPE
  g.tx=cur_tx
  g.ty=cur_ty
  g.x=8*(cur_tx-1)
  g.y=8*(cur_ty-1)
  hole.guard=g
 end
end

function update_guard_box(g)
 if g.carrying then
  g.carry_timer=g.carry_timer-1
  if g.carry_timer<=0 then
   local _,tx,ty=tile_char_at_pixel(g.x+4,g.y+4)
   set_tile_xy(tx,ty,"$")
   g.carrying=false
  end
  return
 end
 local cur,tx,ty=tile_char_at_pixel(g.x+4,g.y+4)
 if cur=="$" and g.state~="trapped" then
  set_tile_xy(tx,ty," ")
  g.carrying=true
  g.carry_timer=GUARD_BOX_CARRY_TICKS+math.random(0,GUARD_BOX_CARRY_RANDOM)
 end
end

function drop_guard_box_in_pit(g)
 if not g.carrying then return end
 local _,tx,ty=tile_char_at_pixel(g.x+4,g.y+4)
 if holes[tx..","..ty] then
  set_tile_xy(tx,ty-1,"$")
  g.carrying=false
  g.carry_timer=0
 end
end

-- classic Lode Runner guard AI: rate every descent/climb point on the guard's
-- current floor segment, then head towards the one that lands nearest the runner

function tile_of(e)
 local _,tx,ty=tile_char_at_pixel(e.x+4,e.y+4)
 return tx,ty
end

-- a tile you can stand on top of
function supports_walking(c)
 return is_solid(c) or is_visible_ladder_char(c)
end

function is_guard_pit(tx,ty)
 return guards_pit_aware and holes[tx..","..ty]~=nil
end

-- a tile you can traverse sideways while standing in it
function can_walk_at(tx,ty)
 if is_guard_pit(tx,ty) then return false end
 if not guards_pit_aware and (holes[tx..","..ty]~=nil or holes[tx..","..(ty+1)]~=nil) then return true end
 local here=tile_xy(tx,ty)
 if is_visible_ladder_char(here) or here=="-" then return true end
 if ty>=level_h then return true end
 local below=tile_xy(tx,ty+1)
 return supports_walking(below) or below=="-" or below=="$"
end

-- a spot the guard could branch off sideways from instead of continuing to fall
function can_branch(tx,ty)
 if is_guard_pit(tx,ty) then return false end
 local below=tile_xy(tx,ty+1)
 return supports_walking(below) or tile_xy(tx,ty)=="-"
end

-- lower is better: reaching the runner's row beats ending above it, which beats ending below it
function scan_rate(x,y,runner_ty,start_x)
 if y==runner_ty then return math.abs(start_x-x) end
 if y>runner_ty then return y-runner_ty+200 end
 return runner_ty-y+100
end

-- follow a fall/descent down column tx, stopping where a sideways escape exists
function scan_down(tx,start_ty,runner_ty)
 local y=start_ty
 while y<level_h and not is_solid(tile_xy(tx,y+1)) do
   if is_guard_pit(tx,y) then return nil end
  local here=tile_xy(tx,y)
  local free=(here==" ") or (here=="h" and not ladders_revealed)
  if not free then
   if tx>1 and can_branch(tx-1,y) and y>=runner_ty then break end
   if tx<level_w and can_branch(tx+1,y) and y>=runner_ty then break end
  end
  y=y+1
 end
 return y
end

-- follow a ladder up column tx, stopping where a sideways escape exists
function scan_up(tx,start_ty,runner_ty)
 local y=start_ty
 while y>1 and is_visible_ladder_char(tile_xy(tx,y)) do
  y=y-1
  if tx>1 and can_branch(tx-1,y) and y<=runner_ty then break end
  if tx<level_w and can_branch(tx+1,y) and y<=runner_ty then break end
 end
 return y
end

function scan_floor(g)
 local start_x,start_y=tile_of(g)
 local _,_,runner_ty=tile_char_at_pixel(runner.x+4,runner.y+4)
 local best_rating=255
 local best_path=nil

 local function rate(tx,y,path)
  local r=scan_rate(tx,y,runner_ty,start_x)
  if r<best_rating then
   best_rating=r
   best_path=path
  end
 end

 local function probe(tx,down_path,up_path)
  if not is_solid(tile_xy(tx,start_y+1)) then
    local landing_y=scan_down(tx,start_y,runner_ty)
    if landing_y then rate(tx,landing_y,down_path) end
  end
  if is_visible_ladder_char(tile_xy(tx,start_y)) then
   rate(tx,scan_up(tx,start_y,runner_ty),up_path)
  end
 end

 -- extent of the contiguous walkable floor segment, including one tile into the drop at each end
 local x=start_x
 while x>1 and not is_solid(tile_xy(x-1,start_y)) do
  local walkable=can_walk_at(x-1,start_y)
  x=x-1
  if not walkable then break end
 end
 local left_end=x

 x=start_x
 while x<level_w and not is_solid(tile_xy(x+1,start_y)) do
  local walkable=can_walk_at(x+1,start_y)
  x=x+1
  if not walkable then break end
 end
 local right_end=x

 probe(start_x,"down","up")

 local path="left"
 x=left_end
 while true do
  if x==start_x then
   if path=="left" and right_end~=start_x then
    path="right"
    x=right_end
   else
    break
   end
  end
  probe(x,path,path)
  if path=="left" then x=x+1 else x=x-1 end
 end

 return best_path
end

-- returns a single action: "left", "right", "up", "down" or nil
function guard_ai(g)
 local gx,gy=tile_of(g)
 local _,rx,ry=tile_char_at_pixel(runner.x+4,runner.y+4)

 -- if the runner shares our floor, walk a virtual cursor across to confirm a path exists
 if gy==ry and not runner.falling then
  local x=gx
  while x~=rx and can_walk_at(x,gy) do
   if x<rx then x=x+1 else x=x-1 end
  end
  if x==rx then
   if g.x<runner.x then return "right" end
   if g.x>runner.x then return "left" end
   return nil
  end
 end

 return scan_floor(g)
end

-- hands out this frame's step budget round-robin; a skipped guard still consumes its slot
function schedule_guards()
 for _,g in ipairs(guards) do g.ready=false end
 local n=#guards
 if n==0 or t%STEP_TICKS~=0 then return end
 move_offset=move_offset+1
 if move_offset>MOVE_CYCLE then move_offset=1 end
 local moves=MOVE_POLICY[math.min(n,#MOVE_POLICY-1)+1][move_offset]
 while moves>0 do
  move_id=move_id+1
  if move_id>n then move_id=1 end
  local g=guards[move_id]
  if g.state~="trapped" then g.ready=true end
  moves=moves-1
 end
end

function update_guard(g)
 if g.state=="trapped" then
  g.trapped_timer=g.trapped_timer-1
  if g.trapped_timer<=0 then
   g.state="run"
   g.y=g.y-8 -- climb out of the pit onto the surface tile above it
   g.falling=false
   g.grace=GUARD_STEP_TICKS*4 -- time to walk clear before gravity re-checks support
   local hole=holes[g.tx..","..g.ty]
   if hole then hole.guard=nil end
  end
  return
 end
 local action=guard_ai(g)
 try_move_horizontal(g,action=="left",action=="right")
 local moved_vert=try_vertical_move(g,action=="up",action=="down")
 apply_gravity(g,moved_vert,action=="down")
 drop_guard_box_in_pit(g)
 check_trap(g)
 update_guard_box(g)
end

function overlaps(a,b)
 return math.abs(a.x-b.x)<6 and math.abs(a.y-b.y)<6
end

function check_guard_collision()
 for _,g in ipairs(guards) do
  if g.state~="trapped" and overlaps(runner,g) then
   lose_life()
   return
  end
 end
end

function lose_life()
 lives=lives-1
 close_all_holes()
 runner.x=runner.spawn_x
 runner.y=runner.spawn_y
 runner.falling=false
 for _,g in ipairs(guards) do
  local hole=holes[g.tx..","..g.ty]
  if hole then hole.guard=nil end
  respawn_guard(g)
 end
 if lives<=0 then
  game_over=true
 end
end

function TIC()
 -- init boxes count once
 if t==0 then
  set_level_bounds()
  boxes_remaining=count_boxes()
 end

 if level_complete and not final_level_complete then
  level_complete_timer=level_complete_timer+1
  if level_complete_timer>=LEVEL_COMPLETE_WAIT then
   if current_level<#level_data then
    load_level(current_level+1)
   else
    final_level_complete=true
   end
  end
 end

 if not game_over and not level_complete then
  -- runner input & movement (disabled while falling, per shared physics)
  runner.ready=(t%STEP_TICKS==0)
  try_move_horizontal(runner,btn(2),btn(3))
  local moved_vert=try_vertical_move(runner,btn(0),btn(1))
  apply_gravity(runner,moved_vert,btn(1))

  -- collect boxes (center overlap)
  local cur_char,cur_tx,cur_ty=tile_char_at_pixel(runner.x+4,runner.y+4)
  if cur_char=="$" then
   set_tile_xy(cur_tx,cur_ty," ")
   if boxes_remaining>0 then boxes_remaining=boxes_remaining-1 end
   if boxes_remaining==0 then ladders_revealed=true end
  end

  -- dig holes to the left/right, into bricks only
  -- Z/Y (key codes are physical-position based, so this covers QWERTY and QWERTZ layouts) or gamepad button 4
  if btnp(4) or keyp(25) or keyp(26) then try_dig(-1) end
  if btnp(5) then try_dig(1) end

  update_holes()
  schedule_guards()
  for _,g in ipairs(guards) do update_guard(g) end
   check_offscreen_falls()
  check_guard_collision()

  -- level complete when all boxes collected and runner reaches top row
  local runner_top_ty=(runner.y+4)//8+1
  if ladders_revealed and runner_top_ty<=1 then
   level_complete=true
  end
 end

 -- draw
 cls(1)
 for ly=1,#(level) do
  local row=level[ly]
  for lx=1,row:len() do
   local position=row:sub(lx,lx)
   local dx=8*(lx-1)
   local dy=8*(ly-1)
   if position=="#" then
    spr(spr_brick,dx,dy,0,1,0,0,1,1)
   end
   if position=="=" then
    spr(spr_floor,dx,dy,0,1,0,0,1,1)
   end
   if position=="H" then
    spr(spr_ladder,dx,dy,0,1,0,0,1,1)
   end
   if position=="h" and ladders_revealed then
    spr(spr_ladder_top,dx,dy,0,1,0,0,1,1)
   end
   if position=="-" then
    spr(spr_bar,dx,dy,0,1,0,0,1,1)
   end
   if position=="$" then
    spr(spr_box,dx,dy,0,1,0,0,1,1)
   end
  end
 end

 -- guards
 for _,g in ipairs(guards) do
  if g.state=="trapped" then
   g.idx=0
   spr(spr_guard_run+g.idx,g.x,g.y,0,1,g.dir,0,1,1)
  else
   local g_cur=tile_char_at_pixel(g.x+4,g.y+4)
   local g_on_ladder=is_visible_ladder_char(g_cur)
   local g_hanging=(g_cur=="-")
   local g_base=spr_guard_run
   local g_idx=0
   if g.falling then
    g_base=spr_guard_fall
    g_idx=0
   elseif g_hanging then
    g_base=spr_guard_hang
    g_idx=g.x%6//2
   elseif g_on_ladder then
    g_base=spr_guard_climb
    g_idx=(g.y%6)//3 -- toggles between 0 and 1
   else
    g_idx=g.x%6//2
    if g.dir==1 then g_idx=2-g_idx end
   end
   g.idx=g_idx
   spr(g_base+g_idx,g.x,g.y,0,1,g.dir,0,1,1)
  end
 end

 -- draw carried boxes after guards so they remain visible on top of the guard sprite
 for _,g in ipairs(guards) do
  if draw_carried_box and g.carrying then
   spr(spr_box,g.x,g.y-8,0,1,0,0,1,1)
  end
 end

 -- runner anim selection
 local cur_char=tile_char_at_pixel(runner.x+4,runner.y+4)
 local on_ladder=is_visible_ladder_char(cur_char)
 local hanging=(cur_char=="-")
 local runner_base=spr_runner_run
 local runner_idx=0

 if runner.falling then
  runner_base=spr_runner_fall
  runner_idx=0
 elseif hanging then
  runner_base=spr_runner_hang
  runner_idx=runner.x%6//2
 elseif on_ladder then
  runner_base=spr_runner_climb
  runner_idx=(runner.y%6)//3 -- toggles between 0 and 1 -> 38/39
 else
  runner_idx=runner.x%6//2
  if runner.dir==1 then runner_idx=2-runner_idx end
 end

 spr(runner_base+runner_idx,runner.x,runner.y,0,1,runner.dir,0,1,1)

 -- HUD
 print("Level:"..current_level.."/"..#level_data,4,4,12)
 if game_over then
  print("GAME OVER",88,12,8)
 elseif final_level_complete then
  print("ALL LEVELS SOLVED!",68,12,12)
 elseif level_complete then
  print("LEVEL COMPLETE!",72,12,12)
  print("NEXT LEVEL IN "..((LEVEL_COMPLETE_WAIT-level_complete_timer+59)//60),76,20,12)
 else
    print("Boxes:"..boxes_remaining,76,4,12)
    print("Lives:"..lives,180,4,12)
 end

 t=t+1
end

