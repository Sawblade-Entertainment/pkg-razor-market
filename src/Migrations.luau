--!strict
--!native
--!optimize 2
-- Ordered migrations: Migrations[n] upgrades data from version n-1 to n.
local Migrations = {}
Migrations.__index = Migrations

function Migrations.new(steps: { (any) -> any })
    for i = 1, #steps do
        assert(type(steps[i]) == "function", `Migration {i} must be a function`)
    end
    return setmetatable({ Steps = steps, Latest = #steps }, Migrations)
end

-- Runs every migration after `fromVersion`. Each step may mutate and/or return data.
function Migrations:Run(data: any, fromVersion: number): (any, number)
    fromVersion = fromVersion or 0
    if fromVersion > self.Latest then
        error(`Data version {fromVersion} is newer than latest {self.Latest}`)
    end
    for v = fromVersion + 1, self.Latest do
        local ok, result = pcall(self.Steps[v], data)
        if not ok then
            error(`Migration {v} failed: {result}`)
        end
        if result ~= nil then
            data = result
        end
    end
    return data, self.Latest
end

-- Fills missing keys from the template (never overwrites existing values).
function Migrations.Reconcile(data: any, template: any): any
    if type(data) ~= "table" then
        data = {}
    end
    for k, v in template do
        if data[k] == nil then
            data[k] = if type(v) == "table" then Migrations.Reconcile({}, v) else v
        elseif type(v) == "table" and type(data[k]) == "table" then
            Migrations.Reconcile(data[k], v)
        end
    end
    return data
end

return Migrations