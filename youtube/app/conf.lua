function love.conf(t)
    t.identity = "ytds-ui"
    t.window.title = "ytds-ui"
    t.window.width = 640
    t.window.height = 480
    t.window.resizable = false
    t.window.vsync = 1
    t.modules.joystick = true
    t.modules.touch = true
    t.modules.thread = true
    t.modules.timer = true
    t.modules.image = true
    t.modules.graphics = true
    t.modules.font = true
    t.modules.filesystem = true
end
