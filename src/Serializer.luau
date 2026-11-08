--!strict
--!native
--!optimize 2
-- Converts Luau/Roblox values to JSON-safe tables and back.
local Serializer = {}

local TAG = "__rz"
local encoders: { [string]: (any) -> any } = {}
local decoders: { [string]: (any) -> any } = {}

local function reg(name: string, enc: (any) -> any, dec: (any) -> any)
    encoders[name] = enc
    decoders[name] = dec
end

---------------------------------------------------------------- base64 (for buffer)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64I = {}
for i = 1, 64 do
    B64I[string.byte(B64, i)] = i - 1
end

local function b64encode(s: string): string
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = string.byte(s, i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chunk = {}
        for j = 3, 0, -1 do
            local idx = bit32.band(bit32.rshift(n, j * 6), 63) + 1
            table.insert(chunk, string.sub(B64, idx, idx))
        end
        if not b then
            chunk[3], chunk[4] = "=", "="
        elseif not c then
            chunk[4] = "="
        end
        table.insert(out, table.concat(chunk))
    end
    return table.concat(out)
end

local function b64decode(s: string): string
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = 0, 3 do
            local ch = string.byte(s, i + j)
            if ch == 61 then -- "="
                pad += 1
                n = n * 64
            else
                n = n * 64 + B64I[ch]
            end
        end
        local bytes = string.char(bit32.rshift(n, 16), bit32.band(bit32.rshift(n, 8), 255), bit32.band(n, 255))
        table.insert(out, string.sub(bytes, 1, 3 - pad))
    end
    return table.concat(out)
end

---------------------------------------------------------------- Roblox datatypes
reg("Vector2", function(v) return { v.X, v.Y } end, function(t) return Vector2.new(t[1], t[2]) end)
reg("Vector3", function(v) return { v.X, v.Y, v.Z } end, function(t) return Vector3.new(t[1], t[2], t[3]) end)
reg("Vector2int16", function(v) return { v.X, v.Y } end, function(t) return Vector2int16.new(t[1], t[2]) end)
reg("Vector3int16", function(v) return { v.X, v.Y, v.Z } end, function(t) return Vector3int16.new(t[1], t[2], t[3]) end)
reg("CFrame", function(v) return { v:GetComponents() } end, function(t) return CFrame.new(table.unpack(t)) end)
reg("Color3", function(v) return { v.R, v.G, v.B } end, function(t) return Color3.new(t[1], t[2], t[3]) end)
reg("BrickColor", function(v) return v.Number end, function(n) return BrickColor.new(n) end)
reg("UDim", function(v) return { v.Scale, v.Offset } end, function(t) return UDim.new(t[1], t[2]) end)
reg("UDim2", function(v)
    return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }
end, function(t)
    return UDim2.new(t[1], t[2], t[3], t[4])
end)
reg("Rect", function(v)
    return { v.Min.X, v.Min.Y, v.Max.X, v.Max.Y }
end, function(t)
    return Rect.new(t[1], t[2], t[3], t[4])
end)
reg("NumberRange", function(v) return { v.Min, v.Max } end, function(t) return NumberRange.new(t[1], t[2]) end)
reg("NumberSequence", function(v)
    local out = {}
    for _, k in v.Keypoints do
        table.insert(out, { k.Time, k.Value, k.Envelope })
    end
    return out
end, function(t)
    local kps = {}
    for _, k in t do
        table.insert(kps, NumberSequenceKeypoint.new(k[1], k[2], k[3]))
    end
    return NumberSequence.new(kps)
end)
reg("ColorSequence", function(v)
    local out = {}
    for _, k in v.Keypoints do
        table.insert(out, { k.Time, k.Value.R, k.Value.G, k.Value.B })
    end
    return out
end, function(t)
    local kps = {}
    for _, k in t do
        table.insert(kps, ColorSequenceKeypoint.new(k[1], Color3.new(k[2], k[3], k[4])))
    end
    return ColorSequence.new(kps)
end)
reg("EnumItem", function(v)
    return { tostring(v.EnumType), v.Name }
end, function(t)
    return (Enum :: any)[t[1]][t[2]]
end)
reg("Enum", function(v) return tostring(v) end, function(s) return (Enum :: any)[s] end)
reg("DateTime", function(v)
    return v.UnixTimestampMillis
end, function(n)
    return DateTime.fromUnixTimestampMillis(n)
end)
reg("Font", function(v)
    return { v.Family, v.Weight.Name, v.Style.Name }
end, function(t)
    return Font.new(t[1], (Enum.FontWeight :: any)[t[2]], (Enum.FontStyle :: any)[t[3]])
end)
reg("PhysicalProperties", function(v)
    return { v.Density, v.Friction, v.Elasticity, v.FrictionWeight, v.ElasticityWeight }
end, function(t)
    return PhysicalProperties.new(t[1], t[2], t[3], t[4], t[5])
end)
reg("Ray", function(v)
    return { v.Origin.X, v.Origin.Y, v.Origin.Z, v.Direction.X, v.Direction.Y, v.Direction.Z }
end, function(t)
    return Ray.new(Vector3.new(t[1], t[2], t[3]), Vector3.new(t[4], t[5], t[6]))
end)
reg("Region3", function(v)
    local min = v.CFrame.Position - v.Size / 2
    local max = v.CFrame.Position + v.Size / 2
    return { min.X, min.Y, min.Z, max.X, max.Y, max.Z }
end, function(t)
    return Region3.new(Vector3.new(t[1], t[2], t[3]), Vector3.new(t[4], t[5], t[6]))
end)
reg("Region3int16", function(v)
    return { v.Min.X, v.Min.Y, v.Min.Z, v.Max.X, v.Max.Y, v.Max.Z }
end, function(t)
    return Region3int16.new(Vector3int16.new(t[1], t[2], t[3]), Vector3int16.new(t[4], t[5], t[6]))
end)
reg("Faces", function(v)
    local out = {}
    for _, n in Enum.NormalId:GetEnumItems() do
        if (v :: any)[n.Name] then
            table.insert(out, n.Name)
        end
    end
    return out
end, function(t)
    local items = {}
    for _, name in t do
        table.insert(items, (Enum.NormalId :: any)[name])
    end
    return Faces.new(table.unpack(items))
end)
reg("Axes", function(v)
    local out = {}
    for _, a in { "X", "Y", "Z" } do
        if (v :: any)[a] then
            table.insert(out, a)
        end
    end
    return out
end, function(t)
    local items = {}
    for _, name in t do
        table.insert(items, (Enum.Axis :: any)[name])
    end
    return Axes.new(table.unpack(items))
end)
reg("TweenInfo", function(v)
    return { v.Time, v.EasingStyle.Name, v.EasingDirection.Name, v.RepeatCount, v.Reverses, v.DelayTime }
end, function(t)
    return TweenInfo.new(t[1], (Enum.EasingStyle :: any)[t[2]], (Enum.EasingDirection :: any)[t[3]], t[4], t[5], t[6])
end)
reg("buffer", function(v)
    return b64encode(buffer.tostring(v))
end, function(s)
    return buffer.fromstring(b64decode(s))
end)

---------------------------------------------------------------- Instances
-- Properties persisted per class (checked with IsA). Extend with RegisterInstanceProperties.
local instanceProps: { [string]: { string } } = {
    BasePart = { "Anchored", "CanCollide", "CanQuery", "CanTouch", "CastShadow", "CFrame", "Size", "Color", "Material", "Transparency", "Reflectance", "Massless" },
    Part = { "Shape" },
    MeshPart = { "TextureID" },
    Model = { "WorldPivot" },
    ValueBase = { "Value" },
    Decal = { "Texture", "Color3", "Transparency", "Face" },
    Light = { "Brightness", "Color", "Enabled", "Shadows" },
    GuiObject = { "Position", "Size", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency", "Visible", "ZIndex", "Rotation" },
    TextLabel = { "Text", "TextColor3", "TextSize", "FontFace" },
    TextButton = { "Text", "TextColor3", "TextSize", "FontFace" },
    ImageLabel = { "Image", "ImageColor3", "ImageTransparency" },
    ImageButton = { "Image", "ImageColor3", "ImageTransparency" },
}

function Serializer.RegisterInstanceProperties(className: string, props: { string })
    instanceProps[className] = instanceProps[className] or {}
    for _, p in props do
        table.insert(instanceProps[className], p)
    end
end

local encode: (any, { [any]: boolean }) -> any
local decode: (any) -> any

local function encodeInstance(inst: Instance, seen)
    local props = {}
    for class, list in instanceProps do
        if inst:IsA(class) then
            for _, p in list do
                local ok, value = pcall(function()
                    return (inst :: any)[p]
                end)
                if ok and value ~= nil and typeof(value) ~= "Instance" then
                    props[p] = encode(value, seen)
                end
            end
        end
    end
    local attrs = {}
    for k, v in inst:GetAttributes() do
        attrs[k] = encode(v, seen)
    end
    local children = {}
    for _, child in inst:GetChildren() do
        if child.Archivable then
            table.insert(children, encodeInstance(child, seen))
        end
    end
    return { C = inst.ClassName, N = inst.Name, P = props, A = attrs, T = inst:GetTags(), K = children }
end

local function decodeInstance(t): Instance
    local inst = Instance.new(t.C)
    inst.Name = t.N
    for p, v in t.P or {} do
        pcall(function()
            (inst :: any)[p] = decode(v)
        end)
    end
    for k, v in t.A or {} do
        inst:SetAttribute(k, decode(v))
    end
    for _, tag in t.T or {} do
        inst:AddTag(tag)
    end
    for _, c in t.K or {} do
        decodeInstance(c).Parent = inst
    end
    return inst
end

---------------------------------------------------------------- Core
-- Custom type extension: RegisterType("MyClass", isFn, encodeFn, decodeFn)
local custom: { { name: string, is: (any) -> boolean } } = {}
function Serializer.RegisterType(name: string, is: (any) -> boolean, enc: (any) -> any, dec: (any) -> any)
    reg("custom:" .. name, enc, dec)
    table.insert(custom, { name = "custom:" .. name, is = is })
end

local function isArray(t): boolean
    local n = #t
    local count = 0
    for k in t do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n then
            return false
        end
        count += 1
    end
    return count == n
end

function encode(value: any, seen: { [any]: boolean }): any
    local t = typeof(value)
    if t == "nil" or t == "boolean" or t == "string" then
        return value
    elseif t == "number" then
        if value ~= value then
            return { [TAG] = "nan" }
        elseif value == math.huge or value == -math.huge then
            return { [TAG] = "inf", v = if value > 0 then 1 else -1 }
        end
        return value
    elseif t == "table" then
        for _, c in custom do
            if c.is(value) then
                return { [TAG] = c.name, v = encoders[c.name](value) }
            end
        end
        assert(not seen[value], "Cannot serialize cyclic table")
        seen[value] = true
        local out
        if isArray(value) then
            out = table.create(#value)
            for i, v in value do
                out[i] = encode(v, seen)
            end
        else
            local stringKeysOnly = value[TAG] == nil
            for k in value do
                if type(k) ~= "string" then
                    stringKeysOnly = false
                    break
                end
            end
            if stringKeysOnly then
                out = {}
                for k, v in value do
                    out[k] = encode(v, seen)
                end
            else -- mixed/non-string keys: store as key/value pairs
                local pairsList = {}
                for k, v in value do
                    table.insert(pairsList, { encode(k, seen), encode(v, seen) })
                end
                out = { [TAG] = "map", v = pairsList }
            end
        end
        seen[value] = nil
        return out
    elseif t == "Instance" then
        return { [TAG] = "Instance", v = encodeInstance(value, seen) }
    elseif encoders[t] then
        return { [TAG] = t, v = encoders[t](value) }
    end
    error(`RazorData: cannot serialize type '{t}'`)
end

function decode(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local tag = value[TAG]
    if tag == nil then
        local out = {}
        for k, v in value do
            out[k] = decode(v)
        end
        return out
    elseif tag == "nan" then
        return 0 / 0
    elseif tag == "inf" then
        return value.v * math.huge
    elseif tag == "map" then
        local out = {}
        for _, kv in value.v do
            out[decode(kv[1])] = decode(kv[2])
        end
        return out
    elseif tag == "Instance" then
        return decodeInstance(value.v)
    elseif decoders[tag] then
        return decoders[tag](value.v)
    end
    warn(`RazorData: unknown type tag '{tag}', leaving raw`)
    return value
end

function Serializer.Encode(value: any): any
    return encode(value, {})
end

function Serializer.Decode(value: any): any
    return decode(value)
end

return Serializer