local BrainballInterpreter = {}
BrainballInterpreter.__index = BrainballInterpreter

-- Unified value resolution
function BrainballInterpreter:resolve_value(s)
    if not s then return 0 end
    s = s:match("^%s*(.-)%s*$")
    
    if s == "chicken" then
        return self.chicken or 0
    end

    local cell_idx = s:match("cell%(([%-%d]+)%)")
    if cell_idx then
        return self:get_cell(tonumber(cell_idx))
    end
    
    return tonumber(s) or 0
end

function BrainballInterpreter:new(code, memory_size)
    local self = setmetatable({}, BrainballInterpreter)
    self.code = code
    self.memory_size = memory_size or 4096
    self.memory = {}
    for i = 0, self.memory_size - 1 do self.memory[i] = 0 end
    
    self.chicken = 0
    self.pointers = {[0] = 0} 
    self.current_pointer_id = 0
    self.output = {}
    self.input_buffer = {}

    -- Initialize the Command Dictionary
    self:init_command_dict()
    
    return self
end

function BrainballInterpreter:init_command_dict()
    self.commands = {
        ["!"] = function(param) 
            self.pointers[self.current_pointer_id] = self:resolve_value(param) % self.memory_size 
        end,
        ["?"] = function(param)
            local dir = param:gsub("%s+", ""):upper()
            local move = (dir == "R") and 1 or (dir == "L" and -1 or 0)
            local cur = self.pointers[self.current_pointer_id]
            self.pointers[self.current_pointer_id] = (cur + move) % self.memory_size
        end,
        ["^"] = function(param)
            self:set_cell(self.pointers[self.current_pointer_id], self:resolve_value(param))
        end,
        ["+"] = function(param)
            local idx = self.pointers[self.current_pointer_id]
            self:set_cell(idx, self:get_cell(idx) + self:resolve_value(param))
        end,
        ["-"] = function(param)
            local idx = self.pointers[self.current_pointer_id]
            self:set_cell(idx, self:get_cell(idx) - self:resolve_value(param))
        end,
        ["="] = function(param)
            local val = self:get_cell(self:resolve_value(param))
            self:set_cell(self.pointers[self.current_pointer_id], val)
        end,
        ["<"] = function(param)
            local src = self:resolve_value(param)
            self:set_cell(self.pointers[self.current_pointer_id], self:get_cell(src))
            self:set_cell(src, 0)
        end,
        ["%"] = function(param)
            local src = self:resolve_value(param)
            local cur = self.pointers[self.current_pointer_id]
            local v1, v2 = self:get_cell(cur), self:get_cell(src)
            self:set_cell(cur, v2)
            self:set_cell(src, v1)
        end,
        [">"] = function()
            local val = self:get_cell(self.pointers[self.current_pointer_id])
            local char = string.char(val % 256)
            table.insert(self.output, char)
            io.write(char)
        end,
        ["@"] = function(param)
            self.chicken = self:get_cell(self:resolve_value(param))
        end,
	[":"] = function(param)
	    local idx = self:resolve_value(param)
	    local char = io.read(1) -- Read exactly one character from the terminal
	    self:set_cell(idx, char and string.byte(char) or 0)
	end,
        ["|"] = function()
            local new_id = 0
            while self.pointers[new_id] do new_id = new_id + 1 end
            self.pointers[new_id] = 0
        end,
        ["*"] = function(param)
            local pid = self:resolve_value(param)
            if self.pointers[pid] then 
                self.current_pointer_id = pid 
            else
                local max_id = 0
                for id in pairs(self.pointers) do if id > max_id then max_id = id end end
                self.current_pointer_id = max_id
            end
        end,
        ["#"] = function(param)
            local pid = self:resolve_value(param)
            if pid ~= 0 and self.pointers[pid] then
                self.pointers[pid] = nil
                self.current_pointer_id = 0
            end
        end
    }
end

function BrainballInterpreter:dump_state(pc, token)
    local cell_range = 20 -- Reduced range for clearer debug output
    local mem_line = ""
    for i = 0, cell_range do
        local val = self.memory[i] or 0
        if i == self.pointers[self.current_pointer_id] then
            mem_line = mem_line .. string.format("[%d]* ", val)
        else
            mem_line = mem_line .. string.format("%d ", val)
        end
    end

    print(string.format(
        "PC: %03d | Cmd: %-10s | PtrID: %d | Chicken: %-3d | Mem: %s",
        pc, 
        (token.type .. (token.value and "("..token.value..")" or "")),
        self.current_pointer_id,
        self.chicken,
        mem_line
    ))
end

function BrainballInterpreter:get_cell(index)
    index = math.floor(index) % self.memory_size
    return self.memory[index] or 0
end

function BrainballInterpreter:set_cell(index, value)
    index = math.floor(index) % self.memory_size
    self.memory[index] = math.floor(value) % 65536
end

function BrainballInterpreter:parse_condition(cond_str)
    local left, op, right = cond_str:match("^%s*(.-)%s*([><=!]+)%s*(.-)%s*$")
    return left, op, right
end

function BrainballInterpreter:eval_single_comparison(s)
    local left_str, op, right_str = self:parse_condition(s)
    if not left_str then return false end
    
    local left_val = self:resolve_value(left_str)
    local right_val = self:resolve_value(right_str)

    if op == ">" then return left_val > right_val
    elseif op == "<" then return left_val < right_val
    elseif op == "==" then return left_val == right_val
    elseif op == "!=" then return left_val ~= right_val
    elseif op == ">=" then return left_val >= right_val
    elseif op == "<=" then return left_val <= right_val
    end
    return false
end

function BrainballInterpreter:eval_condition(cond_str)
    if cond_str:find("||") then
        for part in cond_str:gmatch("([^|]+)") do
            if self:eval_condition(part) then return true end
        end
        return false
    end

    if cond_str:find("%^%^") then
        local parts = {}
        for part in cond_str:gmatch("([^%^]+)") do 
            if part ~= "" then table.insert(parts, part) end 
        end
        local true_count = 0
        for _, p in ipairs(parts) do
            if self:eval_condition(p) then true_count = true_count + 1 end
        end
        return (true_count % 2 == 1)
    end 

    if cond_str:find("&&") then
        for part in cond_str:gmatch("([^&]+)") do
            if not self:eval_condition(part) then return false end
        end
        return true
    end

    return self:eval_single_comparison(cond_str)
end

function BrainballInterpreter:tokenize(code)
    local tokens = {}
    local i = 1
    
    while i <= #code do
        local char = code:sub(i, i)
        local next_char = code:sub(i+1, i+1)

        if char == "/" and next_char == "/" then
            while i <= #code and code:sub(i, i) ~= "\n" do i = i + 1 end
            i = i + 1
        elseif char:match("%s") then
            i = i + 1
        elseif char == "[" then
            table.insert(tokens, {type = "LOOP_START"})
            i = i + 1
        elseif char == "]" then
            i = i + 1
            while i <= #code and code:sub(i, i):match("%s") do i = i + 1 end
            if i <= #code and code:sub(i, i) == "(" then
                local start = i + 1
                local depth = 1
                i = i + 1
                while i <= #code and depth > 0 do
                    if code:sub(i, i) == "(" then depth = depth + 1
                    elseif code:sub(i, i) == ")" then depth = depth - 1 end
                    i = i + 1
                end
                local condition = code:sub(start, i - 2)
                table.insert(tokens, {type = "LOOP_END", value = condition})
            else
                error("']' must be followed by (condition)")
            end
        elseif char == ">" or char == "|" then
            table.insert(tokens, {type = char})
            i = i + 1
        elseif char:match("[!?^+%-%=<:*#@%%]") then
            local cmd = char
            i = i + 1
            while i <= #code and code:sub(i, i):match("%s") do i = i + 1 end
            if i <= #code and code:sub(i, i) == "(" then
                local start = i + 1
                local depth = 1
                i = i + 1
                while i <= #code and depth > 0 do
                    if code:sub(i, i) == "(" then depth = depth + 1
                    elseif code:sub(i, i) == ")" then depth = depth - 1 end
                    i = i + 1
                end
                local param = code:sub(start, i - 2)
                table.insert(tokens, {type = cmd, value = param})
            else
                error("Command '" .. cmd .. "' requires (parameter)")
            end
        else
            i = i + 1
        end
    end
    return tokens
end

function BrainballInterpreter:map_jumps(tokens)
    local jumps = {}
    local stack = {}
    for i, t in ipairs(tokens) do
        if t.type == "LOOP_START" then
            table.insert(stack, i)
        elseif t.type == "LOOP_END" then
            local start = table.remove(stack)
            if not start then error("Unmatched ']'") end
            jumps[start] = i
            jumps[i] = start
        end
    end
    if #stack > 0 then error("Unmatched '['") end
    return jumps
end

function BrainballInterpreter:run(tokens, debug, stepped)
    local jumps = self:map_jumps(tokens)
    local pc = 1

    while pc <= #tokens do
        local token = tokens[pc]
        if debug then 
	    self:dump_state(pc, token) 
	    if stepped then
		io.write(" [Enter: step, q: quit]: ")
            	local input = io.read()
            	if input == "q" then os.exit() end
	    end
	end

        local cmd = token.type
        local param = token.value

        if self.commands[cmd] then
            self.commands[cmd](param)
        elseif cmd == "LOOP_START" then
            local end_pc = jumps[pc]
            if not self:eval_condition(tokens[end_pc].value) then
                pc = end_pc 
            end
        elseif cmd == "LOOP_END" then
            if self:eval_condition(param) then
                pc = jumps[pc] 
            end
        end
        pc = pc + 1
    end
end

-- Main execution block
if arg and arg[0] then
    local args = {...}
    local is_debug = false
    local is_stepd = false
    local code = nil
    local input_str = ""

    local i = 1
    while i <= #args do
        if args[i] == "-d" then
            is_debug = true
	elseif args[i] == "-dS" then
	    is_debug = true
	    is_stepd = true
        elseif args[i] == "-c" then
            code = args[i+1]
            i = i + 1
        else
            local file = io.open(args[i], "r")
            if file then
                code = file:read("*all")
                file:close()
            end
        end
        i = i + 1
    end

    if not code then
        print("Usage: lua brainball.lua [-d|-dS] <filename.bb>")
        os.exit(1)
    end

    local interpreter = BrainballInterpreter:new(code)
    local tokens = interpreter:tokenize(code)
    
    if is_debug then print("\n--- Debug Execution ---") end
    interpreter:run(tokens, is_debug, is_stepd)
    print("")
end

return BrainballInterpreter
