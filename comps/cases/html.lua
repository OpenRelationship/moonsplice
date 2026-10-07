-- Blitz HTML/CSS layer. progress substitutes {{progress}} / {{progress_int}}.
local e = require("moonsplice")

local markup = [[
<div style="width:100%;height:100%;background:#151c2c;color:#e8edf7;font-family:Helvetica,Arial,sans-serif;padding:40px 48px;box-sizing:border-box;border-radius:28px">
  <div style="font-size:14px;letter-spacing:0.28em;color:#3ee0c6">HTML LAYER</div>
  <div style="font-size:64px;font-weight:700;margin-top:12px">{{progress_int}}%</div>
  <div style="margin-top:28px;height:16px;background:#243044;border-radius:8px;overflow:hidden">
    <div style="width:{{progress}}%;height:16px;background:#3ee0c6;border-radius:8px"></div>
  </div>
  <div style="margin-top:18px;font-size:18px;color:#8b97b0">Stylo + Taffy + vello_cpu · no Chrome</div>
</div>
]]

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "11  HTML", size = 22, color = "#6b7894" }

    local card = s:html {
      x = 240, y = 160, w = 800, h = 400,
      html = markup, progress = 8,
    }

    s:script(function(t)
      t:tween(card, 1.7, { progress = 92 }, "cubicInOut")
    end)
  end,
}
