local socket = require("socket")
local cjson = require("cjson")
local http_util = require("http_util")
local table_util = require("table_util")
local https = require("ssl.https")
local date = require("date")
local Orm = require("Orm")
local config = require("config")
local log = require("log")

log.outfile = "reposter.log"

local db = Orm:new()
local db_name = "data.sqlite"

local function to_unit_time(s)
	return date.diff(date(s), date("Jan 01 1970 00:00:00")):spanseconds()
end

local function yt_link(id)
	return "https://youtu.be/" .. id
end

local yt_search = "https://www.googleapis.com/youtube/v3/search"

local function get_videos(channelId)
	local url = yt_search .. "?" .. http_util.encode_query_string({
		key = config.ytKey,
		channelId = channelId,
		part = "snippet,id",
		order = "date",
		maxResults = 5
	})
	log.debug("GET " .. url)
	local body, err = https.request(url)
	if not body then
		return nil, err
	end

	local ok, res = pcall(cjson.decode, body)
	if not ok then
		log.debug(body)
		return nil, res
	elseif res.error then
		return nil, res.error.message
	elseif res.items then
		return res.items
	end

	log.debug(body)
	return nil, "Unknown error"
end

local function get_id(video)
	return video.video_id
end

local function search()
	log.trace("Search videos")

	local channels = {}
	local file = assert(io.open("channels", "r"))
	for line in file:lines() do
		local channelId = line:match("^(%S+).-$")
		if channelId then
			table.insert(channels, channelId)
		end
	end
	log.trace("#channels = " .. #channels)

	local videos = {}
	local videos_by_id = {}
	local i = 0
	for _, channelId in ipairs(channels) do
		io.write(".")
		io.flush()
		local yt_videos, err = get_videos(channelId)
		if not yt_videos then
			io.write("\n")
			log.warn("Can't get videos for " .. channelId)
			log.warn(err)
			break
		end
		for _, video in ipairs(yt_videos) do
			if video.id.kind == "youtube#video" then
				local db_video = {
					video_id = video.id.videoId,
					published_at = to_unit_time(video.snippet.publishedAt),
					title = video.snippet.title,
					description = video.snippet.description,
				}
				table.insert(videos, db_video)
				videos_by_id[db_video.video_id] = db_video
			end
		end
		i = i + 1
	end
	io.write("\n")
	log.trace("Channels updated: " .. i .. "/" .. #channels)
	log.trace("Videos found: " .. #videos)

	local new = table_util.array_update(videos, db:select("videos"), get_id, get_id)

	log.trace("New videos: " .. #new)

	for _, video_id in ipairs(new) do
		log.trace("add " .. yt_link(video_id))
		db:insert("videos", videos_by_id[video_id])
	end
end

local function request_vk(url)
	log.debug("GET " .. url)
	local body, err = https.request(url)
	if not body then
		return nil, err
	end

	local ok, res = pcall(cjson.decode, body)
	if not ok then
		log.debug(body)
		return nil, res
	elseif res.error then
		return nil, res.error.error_msg
	elseif res.error_msg then
		return nil, res.error_msg
	elseif not res.response then
		log.debug(body)
		return nil, "Unknown error"
	end

	return res
end

local function post()
	log.trace("Post videos")

	local videos = db:select("videos", "posted_at IS NULL ORDER BY published_at ASC")
	log.trace("Pending videos: " .. #videos)
	if #videos == 0 then
		return 0
	end

	local video = videos[1]
	log.trace("Add vk video " .. yt_link(video.video_id))

	local url = "https://api.vk.com/method/video.save" .. "?" .. http_util.encode_query_string({
		v = 5.103,
		name = video.title,
		description = video.title .. "\n" .. video.description,
		link = yt_link(video.video_id),
		wallpost = 0,
		group_id = config.vkGroupId,
		access_token = config.vkAccessToken
	})

	local res, err = request_vk(url)
	if not res then
		db:update("videos", {posted_at = 0}, "video_id = ?", video.video_id)
		return nil, err
	end

	socket.sleep(1)

	local vk_video_id = res.response.video_id
	res, err = request_vk(res.response.upload_url)
	if not res then
		db:update("videos", {posted_at = 0}, "video_id = ?", video.video_id)
		return nil, err
	end

	db:update("videos", {posted_at = os.time()}, "video_id = ?", video.video_id)

	url = "https://api.vk.com/method/wall.post" .. "?" .. http_util.encode_query_string({
		v = 5.103,
		owner_id = -config.vkGroupId,
		message = ("%s\n%s\n%s"):format(video.title, video.description, yt_link(video.video_id)),
		attachments = "video" .. -config.vkGroupId .. "_" .. vk_video_id,
		access_token = config.vkAccessToken
	})
	res, err = request_vk(url)
	if not res then
		return nil, err
	end

	return 1
end

local function init()
	db:exec([[
		CREATE TABLE videos (
			id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
			video_id TEXT NOT NULL UNIQUE,
			published_at INTEGER NOT NULL,
			posted_at INTEGER,
			title TEXT NOT NULL,
			description INTEGER NOT NULL
		);
		CREATE INDEX videos_published_at_index ON videos (published_at);
	]])
	search()
	db:update("videos", {posted_at = os.time()})
end

local function remove_30days()
	local videos = db:select("videos", "posted_at IS NOT NULL ORDER BY posted_at ASC LIMIT 1")
	if #videos == 0 then
		return
	end

	if date.diff(os.time(), videos[1].posted_at):spandays() < 30 then
		return
	end

	log.trace("Removing old videos")

	local not_posted = db:select("videos", "posted_at IS NULL")
	log.trace("Keep " .. #not_posted .. " not posted videos")

	db:exec([[
		DROP TABLE IF EXISTS videos;
		DROP INDEX IF EXISTS videos_published_at_index;
	]])

	init()

	log.trace("Bring back " .. #not_posted .. " not posted videos")
	for i = 1, #not_posted do
		db:insert("videos", not_posted[i], true)
		db:update("videos", {posted_at = db.NULL}, "video_id = ?", not_posted[i].video_id)
	end
end

local function run()
	db:open(db_name)
	if not db:table_info("videos") then
		init()
	else
		local posted, err = post()
		if not posted then
			log.warn(err)
		elseif posted == 0 then
			search()
		end
		remove_30days()
	end
	db:close()
end

while true do
	run()
	log.debug("sleep")
	socket.sleep(60 * 60)
end
