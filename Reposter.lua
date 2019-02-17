local db = require("lapis.db")
local http = require("lapis.nginx.http")

local util = require("lapis.util")
local from_json = util.from_json
local encode_query_string = util.encode_query_string

local logFile = io.open("log.txt", "a")
local log = function(...)
	for _, s in ipairs({...}) do
		logFile:write(tostring(s) .. "\n")
	end
end
local logdate = function()
	logFile:write(os.date() .. "\n")
end
local ctime = function()
	return os.date("%H") + os.date("%M") / 60
end

local Reposter = {}

Reposter.vkGroupId = 0
Reposter.vkAppId = 0
Reposter.vkAccessToken = ""
Reposter.vkVideoSaveUrl = "https://api.vk.com/method/video.save"

Reposter.ytKey = ""
Reposter.ytSearchUrl = "https://www.googleapis.com/youtube/v3/search"
Reposter.ytVideoUrl = "https://www.youtube.com/watch?v=%s"

Reposter.search = function(self)
	logdate()
	log([[
------------------------------------------------
-- search start
------------------------------------------------
	]])
	self:updateVideos()
	
	log([[
------------------------------------------------
-- search end
------------------------------------------------
	]])
end

Reposter.update = function(self)
	logdate()
	log([[
------------------------------------------------
-- update start
------------------------------------------------
	]])
	self:loadConfig()
	
	log("ctime == " .. ctime())
	if self.config.sleep == 1 then
		if ctime() > self.config.wakeTime then
			self.config.sleep = 0
			self.config.latestPostTime = 0
			self.config.postedToday = 0
			log("wake up")
		else
			return
		end
	end
	self:postVideos()
	if ctime() > self.config.wakeTime + self.config.postTime then
		self.config.sleep = 1
	end
	
	self:saveConfig()
	
	log([[
------------------------------------------------
-- update end
------------------------------------------------
	]])
end

Reposter.loadConfig = function(self)
	self.config = {}
	
	local config = db.query("SELECT * FROM `config`")
	for _, row in ipairs(config) do
		self.config[row.key] = row.value
	end
end

Reposter.saveConfig = function(self)
	for key, value in pairs(self.config) do
		db.query("UPDATE `config` SET `value` = ? WHERE `key` = ?", value, key)
	end
end

Reposter.updateVideos = function(self)
	log("-- updateVideos")
	
	local channels = db.query("SELECT * FROM `channels`")
	log("#channels == " .. #channels)
	
	for _, channel in ipairs(channels) do
		-- log("id == " .. channel.id)
		local response = self:getVideos(channel.channelId)
		
		if response.items then
			for _, video in ipairs(response.items) do
				if video.id.kind == "youtube#video" then
					self:addVideo(video)
				end
			end
		end
	end
end

Reposter.getVideos = function(self, channelId)
	-- log("-- updateVideos")
	-- log("channelId == " .. channelId)
	
	local url = table.concat({
		self.ytSearchUrl, "?",
		encode_query_string({
			key = self.ytKey,
			channelId = channelId,
			part = "snippet,id",
			order = "date",
			maxResults = 5
		})
	})
	-- log("url == " .. url)
	
	local body, status_code, headers = http.simple(url)
	-- log("body == " .. body)
	-- log("status_code == " .. status_code)
	-- log("headers == " .. tostring(headers))
	
	return from_json(body)
end

Reposter.addVideo = function(self, video)
	log("-- addVideo")
	log("video.id.videoId == " .. video.id.videoId)
	-- 2018-09-18T00:24:26.000Z
	return db.query([[
		INSERT IGNORE INTO `videos`
		(`videoId`, `channelId`, `publishedAt`, `title`, `description`) VALUES
		(?, ?, ?, ?, ?)
		]],
		video.id.videoId,
		video.snippet.channelId,
		video.snippet.publishedAt,
		video.snippet.title,
		video.snippet.description
	)
end

Reposter.postVideos = function(self)
	log("-- updateVideos")
	
	local videos = db.query(
		"SELECT * FROM `videos` WHERE `posted` = 0 ORDER BY `publishedAt` ASC LIMIT ?",
		self.config.postLimit
	)
	log("#videos == " .. #videos)
	
	if #videos == 0 then return end
	
	local postDelay = math.min(
		math.max(
			self.config.postMinDelay,
			(self.config.postTime - ctime() + self.config.wakeTime) / #videos
		),
		self.config.postMaxDelay
	)
	log("#postDelay == " .. postDelay .. " (" .. (self.config.postTime - ctime() + self.config.wakeTime) / #videos .. ")")
	
	if self.config.postedToday == 0 or ctime() - self.config.latestPostTime > postDelay then
		self:postVideo(videos[1])
		self.config.postedToday = self.config.postedToday + 1
		self.config.latestPostTime = ctime()
	end
end

Reposter.postVideo = function(self, video)
	log("-- postVideo")
	log("video.videoId == " .. video.videoId)
	
	local url = table.concat({
		self.vkVideoSaveUrl, "?",
		encode_query_string({
			v = 5.74,
			name = video.title,
			description = video.description,
			wallpost = 1,
			link = self.ytVideoUrl:format(video.videoId),
			group_id = self.vkGroupId,
			message = video.description,
			access_token = self.vkAccessToken
		})
	})
	log("url == " .. url)
	
	local body, status_code, headers = http.simple(url)
	log("body == " .. body)
	log("status_code == " .. status_code)
	log("headers == " .. tostring(headers))
	
	local data = from_json(body)
	
	if data.response then
		log("-- data.response exists, try to post")
		local body, status_code, headers = http.simple(data.response.upload_url)
		log("body == " .. body)
		log("status_code == " .. status_code)
		log("headers == " .. tostring(headers))
		
		db.query(
			"UPDATE `videos` SET `posted` = 1, `postedAt` = CURRENT_TIMESTAMP WHERE `posted` = 0 AND `videoId` = ?",
			video.videoId
		)
		return
	end
end

return Reposter
