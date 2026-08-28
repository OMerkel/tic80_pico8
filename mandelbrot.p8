pico-8 cartridge // http://www.pico-8.com
version 43
__lua__
-- yet another pico-8 mandelbrot viewer

function _init()
  cx, cy = -0.5, 0       -- center
  scale = 3              -- view width in complex plane
  maxit = 32             -- iterations
end

function draw_mandelbrot()
  cls()
  local w,h = 128,128
  for y=0,h-1 do
    local im = cy + (y/h-0.5)*scale
    for x=0,w-1 do
      local re = cx + (x/w-0.5)*scale
      local zr, zi = 0, 0
      local it = 0
      while it < maxit do
        local zr2 = zr*zr - zi*zi + re
        local zi2 = 2*zr*zi + im
        zr, zi = zr2, zi2
        if zr*zr + zi*zi > 4 then break end
        it += 1
      end
      -- simple palette mapping
      local c = (it == maxit) and 0 or (1 + (it % 15))
      pset(x,y,c)
    end
  end
end

function _update()
  -- controls: pan
  local step = 0.1*scale
  if btn(0) then cx -= step end -- left
  if btn(1) then cx += step end -- right
  if btn(2) then cy -= step end -- up
  if btn(3) then cy += step end -- down

  -- zoom in (o) and out (x)
  if btnp(4) then scale *= 0.7 end
  if btnp(5) then scale /= 0.7 end

  -- adjust iterations with hold o+up/down
  if btn(4) and btnp(2) then maxit = min(200, maxit+8) end
  if btn(4) and btnp(3) then maxit = max(8, maxit-8) end
end

function _draw()
  draw_mandelbrot()
  -- hud
  rectfill(0,0,127,6,0)
  print("cx="..tostr(cx,3).." cy="..tostr(cy,3),1,1,7)
  print("scale="..tostr(scale,3).." it="..maxit,1,8,7)
end

__gfx__
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000909000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700090000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000909000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
