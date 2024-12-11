local gimpbatch = require("gimpbatch.gimp_batch")
local ddsfiles = require("ddsfiles")

if not loadStatFile then
	dofile("statdesc.lua")
end
loadStatFile("stat_descriptions.csd")

local function bits(int, s, e)
	return bit.band(bit.rshift(int, s), 2 ^ (e - s + 1) - 1)
end
local function toFloat(int)
	local s = (-1) ^ bits(int, 31, 31)
	local e = bits(int, 23, 30) - 127
	if e == -127 then
		return 0 * s
	end
	local m = 1
	for i = 0, 22 do
		m = m + bits(int, i, i) * 2 ^ (i - 23)
	end
	return s * m * 2 ^ e
end
local function getInt(f)
	local int = f:read(4)
	return int:byte(1) + int:byte(2) * 256 + int:byte(3) * 65536 + int:byte(4) * 16777216
end
local function getLong(f)
	local bytes = f:read(8)
	local a, b, c, d, e, f, g, h = bytes:byte(1, 8)
	return a + b * 256 + c * 65536 + d * 16777216 + e * 4294967296 + f * 1099511627776 + g * 281474976710656 + h * 72057594037927936
end
local function getFloat(f)
	return toFloat(getInt(f))
end
local function getUint16(f)
    -- Read 2 bytes
    local bytes = f:read(2)

    -- Convert the 2 bytes to an unsigned integer (little-endian)
    local b1, b2 = bytes:byte(1, 2)
    local uint16 = b1 + b2 * 256

    return uint16
end
local function round_to(num, decimal_places)
    local multiplier = 10 ^ decimal_places
    return math.floor(num * multiplier + 0.5) / multiplier
end

local function print_table(t, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    if type(t) ~= "table" then
        print(prefix .. tostring(t))
        return
    end

    for key, value in pairs(t) do
        if type(value) == "table" then
            print(prefix .. tostring(key) .. ": {")
            print_table(value, indent + 1)
            print(prefix .. "}")
        else
            print(prefix .. tostring(key) .. ": " .. tostring(value))
        end
    end
end

local function newSheet(name, maxWidth, opacity, maxGroups)
	return {
		name = name,
		maxWidth = maxWidth,
		opacity = opacity,
		maxGroups = maxGroups,
		sprites = { },
		files = {}
	}
end
local function addToSheet(sheet, icon, section, metadata)
	sheet.files[icon] = sheet.files[icon] or {}
	if sheet.files[icon][section] then
		return
	end
	sheet.files[icon][section] = metadata
end
local function calculateSheetCoords(sheet, path_base)
	for i = 0, sheet.maxGroups - 1 do
		local coords = { }
		local sortedFiles = { }
		local lastHeight = 0
		local maxWidthFound = 0
		local group = {
			x=0, 
			y=0,
			w = sheet.maxWidth,
			h = 0,
			filename = sheet.name .. "-" .. i .. ".png",
		}

		for icon, sections in pairs(sheet.files) do
			for section, metadata in pairs(sections) do
				if not metadata[i + 1] then
					goto continue
				end

				local width = metadata[i + 1].width
				local height = metadata[i + 1].height
				local mipmap = ddsfiles.findClosestDDSMipmap( path_base .. string.lower(icon), width, height)

				table.insert(sortedFiles, {
					icon = icon,
					section = section,
					width = width,
					height = height,
					mipmap = mipmap,
				})

				:: continue ::
			end
		end

		table.sort(sortedFiles, function(a, b)
			return a.height < b.height
		end)

		for _, iconInfo in pairs(sortedFiles) do
			if group.x + iconInfo.width > group.w or iconInfo.height ~= lastHeight then
				maxWidthFound = math.max(maxWidthFound, group.x)
				group.x = 0
				group.y = group.y + lastHeight
				group.h = group.y + iconInfo.height
			end
			table.insert(coords, {
				icon = iconInfo.icon,
				x = group.x,
				y = group.y,
				w = iconInfo.width,
				h = iconInfo.height,
				section = iconInfo.section,
				mipmap = iconInfo.mipmap,
			})
			group.x = group.x + iconInfo.width
			lastHeight = iconInfo.height
		end

		group.x = 0
		group.y = 0
		group.coords = coords

		if maxWidthFound < group.w then
			group.w = maxWidthFound
		end

		table.insert(sheet.sprites, group)
	end

	sheet.files = {}
end

local function generateSprite(sheet, path_base, path_out,executeCommand)
	for i, group in ipairs(sheet.sprites) do
		gimpbatch.combine_dds_to_sprite(
			sheet.name .. "-" .. (i-1),
			group,
			path_base,
			path_out, GetRuntimePath() .. "/lua/gimpbatch/combine_dds.scm",
			sheet.opacity,
			executeCommand
		)
	end
end

local function extractFromGgpk(listToExtract)
	local sweetSpotCharacter = 6000
	printf("Extracting ...")
	local fileList = ''
	for _, fname in ipairs(listToExtract) do
		fileList = fileList .. '"' .. string.lower(fname) .. '" '

		if fileList:len() > sweetSpotCharacter then
			main.ggpk:ExtractFilesWithBun(fileList)
			fileList = ''
		end
	end

	if fileList:len() > 0 then
		main.ggpk:ExtractFilesWithBun(fileList)
		fileList = ''
	end
end

--[[
	===== Extraction =====
	Extraction of passives tree from psg file
	workflow:
		- read data file
		- get psg file
		- parse psg file
			- check version (only support version 3 for now)
--]]


-- Set to true if you want to generate assets
local generateAssets = false
-- Find a way to get the default passive tree
local idPassiveTree = 'Default'
-- Find a way to get version
local basePath = GetWorkDir() .. "/../TreeData/"
local version = "4_0"
local path = basePath .. version .. "/"
local fileTree = path .. "tree.lua"

printf("Getting passives tree...")

local rowPassiveTree =  dat("passiveskilltrees"):GetRow("Id", idPassiveTree)

if rowPassiveTree == nil then
	printf("Passive tree not found")
	return
end

local psgFile = rowPassiveTree.PassiveSkillGraph .. ".psg"

printf("Extracting passives tree " .. idPassiveTree .. " from " .. psgFile)

extractFromGgpk({psgFile})

printf("Parsing passives tree " .. idPassiveTree .. " from " .. main.ggpk.oozPath .. psgFile)

local f = io.open(main.ggpk.oozPath .. psgFile, "rb")

-- validate version
local pgb_version = getUint16(f)
if pgb_version ~= 3 then
	printf("Version " .. version .. " not supported")
	return
end

f:read(11)

local psg = { 
	passives = { },
	groups = { },
}

printf("Parsing passives...")
local passivesCount = getInt(f)

printf("Passive count: " .. passivesCount)
for i = 1 , passivesCount do
	table.insert(psg.passives, getLong(f))
end

printf("Parsing groups...")
local groupCount = getInt(f)

printf("Group count: " .. groupCount)
for i = 1 , groupCount do
	local group = { 
		x = getFloat(f),
		y = getFloat(f),
		flags = getInt(f),
		unk1 = getInt(f),
		unk2 = f:read(1):byte(),
		passives = { },
	}

	local passiveCount = getInt(f)
	for j = 1, passiveCount do
		local passive = {
			id = getInt(f),
			radious = getInt(f),
			position = getInt(f),
			connections = { },
		}

		local connectionCount = getInt(f)

		for k = 1, connectionCount do
			table.insert(passive.connections, {
				id = getInt(f),
				radious = getInt(f),
			})
		end

		table.insert(group.passives, passive)
	end

	table.insert(psg.groups, group)
end

f:close()

printf("Passives tree " .. idPassiveTree .. " parsed")

-- uncomment next line if wanna print what we found
-- print_table(psg, 0)

--[[
	===== Generation =====
	Generation of passives tree from psg file
	workflow:
		- generate classes
		- generate groups
		- generate nodes
		- generate sprites (with sprite sheet)
		- generate zoom levels
		- generate constants
--]]

-- we use functions to generate a new table and not shared table
function skillNormalMetadata() 
	return {
		{
			width = 8,
			height = 8,
		},
		{
			width = 16,
			height = 16,
		},
		{
			width = 32,
			height = 32,
		},
		{
			width = 64,
			height = 64,
		}
	}
end
function skillKeystoneMetadata ()
	return {
		{
			width = 16,
			height = 16,
		},
		{
			width = 32,
			height = 32,
		},
		{
			width = 64,
			height = 64,
		},
		{
			width = 128,
			height = 128,
		}
	}
end
function skillNotableMetadata()
	return {
		{
			width = 16,
			height = 16,
		},
		{
			width = 32,
			height = 32,
		},
		{
			width = 64,
			height = 64,
		},
		{
			width = 128,
			height = 128,
		}
	}
end
function masteryMetadata()
	return {
		{
			width = 32,
			height = 32,
		},
		{
			width = 64,
			height = 64,
		},
		{
			width = 128,
			height = 128,
		},
		{
			width = 256,
			height = 256,
		}
	}
end

local defaultMaxWidth = 86*14
local maxGroups = 5 -- this is base on imageZoomLevels
local sheets = {
	newSheet("skills",  defaultMaxWidth, 100, maxGroups),
	newSheet("skills-disabled", defaultMaxWidth, 60, maxGroups),
	newSheet("mastery", defaultMaxWidth, 100, maxGroups),
	newSheet("mastery-active-selected", defaultMaxWidth, 100, maxGroups),
	newSheet("mastery-disabled", defaultMaxWidth, 60, maxGroups),
	newSheet("mastery-connected", defaultMaxWidth, 100, maxGroups),
}
local sheetLocations = {
	["skills"] = 1,
	["skills-disabled"] = 2,
	["mastery"] = 3,
	["mastery-active-selected"] = 4,
	["mastery-disabled"] = 5,
	["mastery-connected"] = 6,
}

local function getSheet(sheetLocation)
	return sheets[sheetLocations[sheetLocation]]
end


local tree = {
	["pob"] = 1,
	["tree"] = idPassiveTree,
	["min_x"]= 0,
    ["min_y"]= 0,
    ["max_x"]= 0,
    ["max_y"]= 0,
	["classes"] = {},
	["groups"] = { },
	["nodes"]= { },	
	["sprites"] = {},
	["imageZoomLevels"] = {
        0.1246,
        0.2109,
        0.2972,
        0.3835,
		0.9013 -- calculate
	},
	["constants"]= { -- calculate this
        ["classes"]= {
            ["StrDexIntClass"]= 0,
            ["StrClass"]= 1,
            ["DexClass"]= 2,
            ["IntClass"]= 3,
            ["StrDexClass"]= 4,
            ["StrIntClass"]= 5,
            ["DexIntClass"]= 6
        },
        ["characterAttributes"]= {
            ["Strength"]= 0,
            ["Dexterity"]= 1,
            ["Intelligence"]= 2
        },
        ["PSSCentreInnerRadius"]= 130,
        ["skillsPerOrbit"]= {},
        ["orbitRadii"]= {
			0, 82, 162, 335, 493, 662, 846, 251, 1080, 1322
        }
    },
}

printf("Generating classes...")
local ignoreFilter = "^%[DNT%]"
for i, classId in ipairs(psg.passives) do
	local passiveRow = dat("passiveskills"):GetRow("PassiveSkillNodeId", classId)
	if passiveRow == nil then
		printf("Class " .. passiveRow.id .. " not found")
		goto continue
	end

	if passiveRow.Name:find(ignoreFilter) ~= nil then
		printf("Ignoring class " .. passiveRow.Name)
		goto continue
	end

	local listCharacters = passiveRow.ClassStart
	
	if listCharacters == nil then
		printf("Characters not found")
		goto continue
	end

	for j, character in ipairs(listCharacters) do
		if character.Name:find(ignoreFilter) ~= nil then
			printf("Ignoring character " .. character.Name)
			goto continue2
		end
		local classDef = {
			["name"] = character.Name,
			["base_str"] = character.BaseStrength,
			["base_dex"] = character.BaseDexterity,
			["base_int"] = character.BaseIntelligence,
			["ascendancies"] = {},
		}

		local ascendancies = dat("ascendancy"):GetRowList("Class", character)
		for k, ascendency in ipairs(ascendancies) do
			if ascendency.Name:find(ignoreFilter) ~= nil then
				printf("Ignoring ascendency " .. ascendency.Name .. " for class " .. character.Name)
				goto continue3
			end
			table.insert(classDef.ascendancies, {
				["id"] = ascendency.Name,
				["name"] = ascendency.Name,
			})

			:: continue3 ::
		end

		if #classDef.ascendancies == 0 then
			printf("No ascendancies found for class " .. character.Name)
			goto continue2
		end
		table.insert(tree.classes,classDef)
		:: continue2 ::
	end
	:: continue ::
end


printf("Generating tree groups...")
local nodesIn = {}
local orbitsConstants = { }
for i, group in ipairs(psg.groups) do
	tree.min_x = math.min(tree.min_x, group.x)
	tree.min_y = math.min(tree.min_y, group.y)
	tree.max_x = math.max(tree.max_x, group.x)
	tree.max_y = math.max(tree.max_y, group.y)

	local treeGroup = {
		["x"] = round_to(group.x, 2),
		["y"] = round_to(group.y, 2),
		["orbits"] ={},
		["nodes"] = {}
	}

	local orbits = { }
	for j, passive in ipairs(group.passives) do
		local node = {
			["skill"] = passive.id,
			["group"] = i,
			["orbit"] = passive.radious,
			["orbitIndex"] = passive.position,
			["in"] = {},
			["out"] = {},	
		}

		-- Get Information from passive Skill
		local passiveRow = dat("passiveskills"):GetRow("PassiveSkillNodeId", passive.id)
		if passiveRow == nil then
			printf("Passive skill " .. passive.id .. " not found")
		else
			if passiveRow.Name:find(ignoreFilter) ~= nil then
				printf("Ignoring passive skill " .. passiveRow.Name)
				goto exitnode
			end
			node["name"] = passiveRow.Name
			node["icon"] = passiveRow.Icon
			if passiveRow.Keystone then
				node["isKeystone"] = true
				addToSheet(getSheet("skills"), passiveRow.Icon, "keystoneActive", skillKeystoneMetadata())
				addToSheet(getSheet("skills-disabled"), passiveRow.Icon, "keystoneInactive", skillKeystoneMetadata())
			elseif passiveRow.Notable then
				node["isNotable"] = true
				addToSheet(getSheet("skills"), passiveRow.Icon, "notableActive", skillNotableMetadata())
				addToSheet(getSheet("skills-disabled"), passiveRow.Icon, "notableInactive", skillNotableMetadata())
			elseif passiveRow.Mastery then
				-- for now ignore mastery current version doesnt Use
				printf("Ignoring mastery " .. passiveRow.Name)
				goto exitnode
				node["isMastery"] = true
				node["inactiveIcon"] = passiveRow.MasteryGroup.IconInactive
				node["activeIcon"] = passiveRow.MasteryGroup.IconActive
				
				addToSheet(getSheet("mastery"), passiveRow.Icon, "mastery", masteryMetadata())
				addToSheet(getSheet("mastery-disabled"), passiveRow.MasteryGroup.IconInactive, "masteryInactive", masteryMetadata())
				addToSheet(getSheet("mastery-connected"), passiveRow.MasteryGroup.IconInactive, "masteryConnected", masteryMetadata())
				addToSheet(getSheet("mastery-active-selected"), passiveRow.MasteryGroup.IconActive, "masteryActiveSelected", masteryMetadata())

				node["masteryEffects"] = {}

				for _, masteryEffect in ipairs(passiveRow.MasteryGroup.MasteryEffects) do
					local effect = {
						effect = masteryEffect.Hash,
						stats = {},
					}

					for _, stat in ipairs(masteryEffect.Stats) do
						table.insert(effect.stats, stat.Id)
					end

					table.insert(node["masteryEffects"], effect)
				end
			else
				addToSheet(getSheet("skills"), passiveRow.Icon, "normalActive", skillNormalMetadata())
				addToSheet(getSheet("skills-disabled"), passiveRow.Icon, "normalInactive", skillNormalMetadata())
			end

			-- Ascendancy
			if passiveRow.Ascendancy ~= nil then
				if passiveRow.Ascendancy.Name:find(ignoreFilter) ~= nil then
					printf("Ignoring node ascendancy " .. passiveRow.Ascendancy.Name)
					goto exitnode
				end
				node["ascendancyName"] = passiveRow.Ascendancy.Name
				node["isAscendancyStart"] = passiveRow.AscendancyStart or nil
			end

			-- Stats
			if passiveRow.Stats ~= nil then
				node["stats"] = {}
				local parseStats = {}
				for k, stat in ipairs(passiveRow.Stats) do
					parseStats[stat.Id] = { min = passiveRow["Stat" .. k], max = passiveRow["Stat" .. k] }
				end
				local out, orders = describeStats(parseStats)
				for k, line in ipairs(out) do
					table.insert(node["stats"], line)
				end
			end

		end
		
		for k, connection in ipairs(passive.connections) do
			-- validate connection to itself and not allow
			if connection.id == passive.id then
				printf("Node " .. passive.id .. " has a connection to itself")
				goto nextconnection
			end
			table.insert(node.out, tostring(connection.id))
			if nodesIn[connection.id] == nil then
				nodesIn[connection.id] = {}
			end
			nodesIn[connection.id][passive.id] = true
			:: nextconnection ::
		end

		-- classStartIndex: is this node exist in psg.passives
		for k, classStartIndex in ipairs(psg.passives) do
			if classStartIndex == passive.id then
				node["classStartIndex"] = k - 1
				break
			end
		end

		orbits[passive.radious + 1] = true
		orbitsConstants[passive.radious + 1] = math.max(orbitsConstants[passive.radious + 1] or 1, passive.position)
		tree.nodes[passive.id] = node
		table.insert(treeGroup.nodes, tostring(passive.id))
		:: exitnode ::
	end

	for orbit, _ in pairs(orbits) do
		table.insert(treeGroup.orbits, orbit - 1)
	end

	if #treeGroup.nodes > 0 then
		tree.groups[i] = treeGroup
	else
		printf("Group " .. i .. " is empty")
	end
end

-- updating skillsPerOrbit
printf("Updating skillsPerOrbit...")
for i, orbit in ipairs(orbitsConstants) do
	-- only even number or go to up even number
	if orbit % 2 == 1 then
		orbit = orbit + 1
	end
	tree.constants.skillsPerOrbit[i] = orbit
end

-- mapping nodes in base on nodes out
printf("Mapping nodes...")
-- print_table(nodesIn, 0)
for id, inIds in pairs(nodesIn) do
	for inId, _ in pairs(inIds) do
		if tree.nodes[id] == nil then
			printf("Node " .. inId .. " not found")
			-- remove from out
			local node = tree.nodes[inId]
			for i, outId in ipairs(node.out) do
				if tonumber(outId) == id then
					table.remove(node.out, i)
					break
				end
			end
			goto continuepassive
		end
		if id == inId then
			printf("Node " .. id .. " has a connection to itself")
			goto continuepassive
		end
		table.insert(tree.nodes[id]["in"], tostring(inId))
		:: continuepassive ::
	end
end

MakeDir(basePath .. version)

printf("Generating list to extract dds from sheets...")
local listDds = {}
for i, sheet in ipairs(sheets) do
	for icon, _ in pairs(sheet.files) do
		listDds[icon] = true
	end
end

local fileList = { }
for icon, _ in pairs(listDds) do
	table.insert(fileList, icon)
end
extractFromGgpk(fileList)

printf("Generating sprite info...")
local sections = {}
for i, sheet in ipairs(sheets) do
	printf("Calculating sprite dimensions for " .. sheet.name)
	calculateSheetCoords(sheet, main.ggpk.oozPath)

	printf("Generating sprite sheet images...")
	generateSprite(sheet, main.ggpk.oozPath, basePath .. version .. "/", generateAssets)

	printf("Generating sprite info for " .. sheet.name)
	-- now we are going to creeate sprites base on section and zoom level
	-- this is base on imageZoomLevels
	for j, group in ipairs(sheet.sprites) do
		local zoomLevel = tree.imageZoomLevels[j]
		for _, coords in pairs(group.coords) do
			local icon = coords.icon
			local sprite = {
				x = coords.x,
				y = coords.y,
				w = coords.w,
				h = coords.h,
			}

			if sections[coords.section] == nil then
				sections[coords.section] = {}
			end
			if sections[coords.section][zoomLevel] == nil then
				sections[coords.section][zoomLevel] = {
					filename = group.filename,
					w = group.w,
					h = group.h,
					coords = { },
				}
			end

			sections[coords.section][zoomLevel].coords[icon] = sprite
			:: continue ::
		end
	end
end

tree.sprites = sections

printf("Generating file in " .. fileTree)
local out, err = io.open(fileTree, "w")
if out == nil then
	printf("Error opening file " .. fileTree)
	printf(err)
	return
end
out:write('return ')
writeLuaTable(out, tree, 1)
out:close()
printf("File " .. fileTree .. " generated")