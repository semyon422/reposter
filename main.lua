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

local ytVideoUrl = "https://youtu.be/"

local function parseVideo(video)
	return {
		video_id = video.id.videoId,
		published_at = to_unit_time(video.snippet.publishedAt),
		title = video.snippet.title,
		description = video.snippet.description,
	}
end

local function getVideos(channelId)
	local body = https.request("https://www.googleapis.com/youtube/v3/search" .. "?" .. http_util.encode_query_string({
		key = config.ytKey,
		channelId = channelId,
		part = "snippet,id",
		order = "date",
		maxResults = 5
	}))

	local ok, res = pcall(cjson.decode, body)
	if not ok then
		log.debug(body)
		return nil, res
	end

	if res.error then
		return nil, res.error.message
	end

	if res.items then
		return res.items
	end

	log.debug(body)
	return nil, "Unknown error"
end

local function vid_id(video)
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

	local foundVideos = {}
	local foundVideosMap = {}
	local i = 0
	for _, channelId in ipairs(channels) do
		io.write(".")
		io.flush()
		local videos, err = getVideos(channelId)
		if not videos then
			io.write("\n")
			log.warn("Can't get videos for " .. channelId)
			log.warn(err)
			break
		end
		for _, video in ipairs(videos) do
			if video.id.kind == "youtube#video" then
				local db_video = parseVideo(video)
				table.insert(foundVideos, db_video)
				foundVideosMap[db_video.video_id] = db_video
			end
		end
		i = i + 1
	end
	io.write("\n")
	log.trace("Channels updated: " .. i .. "/" .. #channels)
	log.trace("Videos found: " .. #foundVideos)

	local localVideos = db:select("videos")

	local new, old, all = table_util.array_update(foundVideos, localVideos, vid_id, vid_id)

	log.trace("New videos: " .. #new)

	for _, video_id in ipairs(new) do
		log.trace("add " .. ytVideoUrl .. video_id)
		db:insert("videos", foundVideosMap[video_id])
	end
end

local function vkRequest(url)
	log.debug("GET " .. url)
	local body = https.request(url)

	local ok, res = pcall(cjson.decode, body)
	if not ok then
		log.debug(body)
		return nil, res
	elseif res.error then
		return nil, res.error.error_msg
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
	log.trace("Add vk video " .. ytVideoUrl .. video.video_id)

	local url = "https://api.vk.com/method/video.save" .. "?" .. http_util.encode_query_string({
		v = 5.103,
		name = video.title,
		description = video.title .. "\n" .. video.description,
		link = ytVideoUrl .. video.video_id,
		wallpost = 0,
		group_id = config.vkGroupId,
		access_token = config.vkAccessToken
	})

	local res, err = vkRequest(url)
	if not res then
		return nil, err
	end

	socket.sleep(1)

	local vk_video_id = res.response.video_id
	res, err = vkRequest(res.response.upload_url)
	if not res then
		return nil, err
	end

	db:update("videos", {posted_at = os.time()}, "video_id = ?", video.video_id)

	url = "https://api.vk.com/method/wall.post" .. "?" .. http_util.encode_query_string({
		v = 5.103,
		owner_id = -config.vkGroupId,
		message = ("%s\n%s\n%s"):format(video.title, video.description, ytVideoUrl .. video.video_id),
		attachments = "video" .. -config.vkGroupId .. "_" .. vk_video_id,
		access_token = config.vkAccessToken
	})
	res, err = vkRequest(url)
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
		CREATE INDEX videos_published_at_IDX ON videos (published_at);
	]])
	search()
	db:update("videos", {posted_at = os.time()})
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
	end
	db:close()
end

while true do
	run()
	log.debug("sleep")
	socket.sleep(60 * 60)
end
