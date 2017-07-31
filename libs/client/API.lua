local json = require('json')
local timer = require('timer')
local http = require('coro-http')
local package = require('../../package.lua')
local Date = require('utils/Date')
local Mutex = require('utils/Mutex')
local endpoints = require('endpoints')

local request = http.request
local f, gsub, byte = string.format, string.gsub, string.byte
local max, random = math.max, math.random
local encode, decode = json.encode, json.decode
local insert, concat = table.insert, table.concat
local difftime = os.difftime
local sleep = timer.sleep
local running = coroutine.running

local BASE_URL = "https://discordapp.com/api/v7"

local BOUNDARY = 'Discordia' .. os.time()
local BOUNDARY2 = '--' .. BOUNDARY
local BOUNDARY3 = BOUNDARY2 .. '--'

local JSON = 'application/json'
local MULTIPART = f('multipart/form-data;boundary=%s', BOUNDARY)

local parseDate = Date.parseHeader

local function parseErrors(ret, errors, key)
	for k, v in pairs(errors) do
		if k == '_errors' then
			for _, err in ipairs(v) do
				insert(ret, f('%s in %s : %s', err.code, key or 'payload', err.message))
			end
		else
			if key then
				parseErrors(ret, v, f(k:find("^[%a_][%a%d_]*$") and '%s.%s' or '%s[%q]', key, k))
			else
				parseErrors(ret, v, k)
			end
		end
	end
	return concat(ret, '\n\t')
end

local majors = {guilds = true, channels = true}

local function route(method, endpoint)

	-- special case for reactions
	local _, n = endpoint:find('reactions')
	if n then
		endpoint = endpoint:sub(1, n)
	end

	-- remove the ID from minor routes
	endpoint = endpoint:gsub('(%a+)/%d+', function(path)
		return not majors[path] and path
	end)

	-- special case for message deletions
	if method == 'DELETE' then
		local i, j = endpoint:find('/channels/%d+/messages')
		if i == 1 and j == #endpoint then
			endpoint = method .. endpoint
		end
	end

	return endpoint

end

local function attachFiles(payload, files)
	local ret = {
		BOUNDARY2,
		'Content-Disposition:form-data;name="payload_json"',
		'Content-Type:application/json\r\n',
		payload,
	}
	for i, v in ipairs(files) do
		insert(ret, BOUNDARY2)
		insert(ret, f('Content-Disposition:form-data;name="file%i";filename=%q', i, v[1]))
		insert(ret, 'Content-Type:application/octet-stream\r\n')
		insert(ret, v[2])
	end
	insert(ret, BOUNDARY3)
	return concat(ret, '\r\n')
end

local mutexMeta = {
	__mode = 'v',
	__index = function(self, k)
		self[k] = Mutex()
		return self[k]
	end
}

local function tohex(c)
	return f('%%%02X', byte(c))
end

local function urlencode(str)
	return gsub(tostring(str), '%W', tohex)
end

local API = require('class')('API')

function API:__init(client)
	self._client = client
	self._mutexes = setmetatable({}, mutexMeta)
end

function API:authenticate(token)
	self._headers = {
		{'Authorization', token},
		{'User-Agent', f('DiscordBot (%s, %s)', package.homepage, package.version)},
	}
	-- return self:getCurrentUser() -- TODO: active this on release
	return decode(encode({id = '1234', bot = token:find('Bot')}))
end

function API:request(method, endpoint, payload, query, files)

	local _, main = running()
	if main then
		return nil, 'Cannot make HTTP request outside of a coroutine'
	end

	local url = BASE_URL .. endpoint

	if query and next(query) then
		local buffer = {}
		for k, v in pairs(query) do
			insert(buffer, f('%s=%s', urlencode(k), urlencode(v)))
		end
		url = f('%s?%s', url, concat(buffer, '&'))
	end

	local req
	if method:find('P') == 1 then
		payload = payload and encode(payload) or '{}'
		req = {}
		for i, v in ipairs(self._headers) do
			req[i] = v
		end
		if files and next(files) then
			payload = attachFiles(payload, files)
			insert(req, {'Content-Type', MULTIPART})
		else
			insert(req, {'Content-Type', JSON})
		end
		insert(req, {'Content-Length', #payload})
	else
		req = self._headers
	end

	local mutex = self._mutexes[route(method, endpoint)]

	mutex:lock()
	local data, err, delay = self:commit(method, url, req, payload, 0)
	mutex:unlockAfter(delay)

	if data then
		return data
	else
		return nil, err
	end

end

function API:commit(method, url, req, payload, retries)

	local client = self._client
	local options = client._options
	local delay = options.routeDelay

	local success, res, msg = pcall(request, method, url, req, payload)

	if not success then
		return nil, res, delay
	end

	for i, v in ipairs(res) do
		res[v[1]] = v[2]
		res[i] = nil
	end

	local reset = res['X-RateLimit-Reset']
	local remaining = res['X-RateLimit-Remaining']

	if reset and remaining == '0' then
		local dt = difftime(reset, parseDate(res['Date']))
		delay = max(1000 * dt, delay)
	end

	local data = res['Content-Type'] == JSON and decode(msg) or msg

	if res.code < 300 then

		client:debug('%i - %s : %s %s', res.code, res.reason, method, url)
		return data, nil, delay

	else

		if type(data) == 'table' then

			local retry
			if res.code == 429 then -- TODO: global ratelimiting
				delay = data.retry_after
				retry = retries < options.maxRetries
			elseif res.code == 502 then
				delay = delay + random(2000)
				retry = retries < options.maxRetries
			end

			if retry then
				client:warning('%i - %s : retrying after %i ms : %s %s', res.code, res.reason, delay, method, url)
				sleep(delay)
				return self:commit(method, url, req, payload, retries + 1)
			end

			if data.code and data.message then
				msg = f('HTTP Error %i : %s', data.code, data.message)
			else
				msg = 'HTTP Error'
			end
			if data.errors then
				msg = parseErrors({msg}, data.errors)
			end

		end

		client:error('%i - %s : %s %s', res.code, res.reason, method, url)
		return nil, msg, delay

	end

end

-- start of auto-generated methods --

function API:getChannel(channel_id) -- not exposed, use cache
	local endpoint = f(endpoints.CHANNEL, channel_id)
	return self:request("GET", endpoint)
end

function API:modifyChannel(channel_id, payload) -- Channel:_modify
	local endpoint = f(endpoints.CHANNEL, channel_id)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteChannel(channel_id) -- Channel:delete
	local endpoint = f(endpoints.CHANNEL, channel_id)
	return self:request("DELETE", endpoint)
end

function API:getChannelMessages(channel_id, query) -- TextChannel:get[First|Last]Message, TextChannel:getMessageHistory
	local endpoint = f(endpoints.CHANNEL_MESSAGES, channel_id)
	return self:request("GET", endpoint, nil, query)
end

function API:getChannelMessage(channel_id, message_id) -- TextChannel:getMessage fallback
	local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
	return self:request("GET", endpoint)
end

function API:createMessage(channel_id, payload, files) -- TextChannel:send
	local endpoint = f(endpoints.CHANNEL_MESSAGES, channel_id)
	return self:request("POST", endpoint, payload, nil, files)
end

function API:createReaction(channel_id, message_id, emoji, payload) -- Message:react
	local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_ME, channel_id, message_id, emoji)
	return self:request("PUT", endpoint, payload)
end

function API:deleteOwnReaction(channel_id, message_id, emoji) -- Reaction:delete
	local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_ME, channel_id, message_id, emoji)
	return self:request("DELETE", endpoint)
end

function API:deleteUserReaction(channel_id, message_id, emoji, user_id) -- Reaction:delete
	local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_USER, channel_id, message_id, emoji, user_id)
	return self:request("DELETE", endpoint)
end

function API:getReactions(channel_id, message_id, emoji) -- Reaction:getUsers
	local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION, channel_id, message_id, emoji)
	return self:request("GET", endpoint)
end

function API:deleteAllReactions(channel_id, message_id) -- Message:clearReactions
	local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTIONS, channel_id, message_id)
	return self:request("DELETE", endpoint)
end

function API:editMessage(channel_id, message_id, payload) -- Message:_modify
	local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteMessage(channel_id, message_id) -- Message:delete
	local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
	return self:request("DELETE", endpoint)
end

function API:bulkDeleteMessages(channel_id, payload) -- GuildTextChannel:bulkDelete
	local endpoint = f(endpoints.CHANNEL_MESSAGES_BULK_DELETE, channel_id)
	return self:request("POST", endpoint, payload)
end

function API:editChannelPermissions(channel_id, overwrite_id, payload) -- various PermissionOverwrite methods
	local endpoint = f(endpoints.CHANNEL_PERMISSION, channel_id, overwrite_id)
	return self:request("PUT", endpoint, payload)
end

function API:getChannelInvites(channel_id) -- GuildChannel:getInvites
	local endpoint = f(endpoints.CHANNEL_INVITES, channel_id)
	return self:request("GET", endpoint)
end

function API:createChannelInvite(channel_id, payload) -- GuildChannel:createInvite
	local endpoint = f(endpoints.CHANNEL_INVITES, channel_id)
	return self:request("POST", endpoint, payload)
end

function API:deleteChannelPermission(channel_id, overwrite_id) -- PermissionOverwrite:delete
	local endpoint = f(endpoints.CHANNEL_PERMISSION, channel_id, overwrite_id)
	return self:request("DELETE", endpoint)
end

function API:triggerTypingIndicator(channel_id, payload) -- TextChannel:broadcastTyping
	local endpoint = f(endpoints.CHANNEL_TYPING, channel_id)
	return self:request("POST", endpoint, payload)
end

function API:getPinnedMessages(channel_id) -- TextChannel:getPinnedMessages
	local endpoint = f(endpoints.CHANNEL_PINS, channel_id)
	return self:request("GET", endpoint)
end

function API:addPinnedChannelMessage(channel_id, message_id, payload) -- Message:pin
	local endpoint = f(endpoints.CHANNEL_PIN, channel_id, message_id)
	return self:request("PUT", endpoint, payload)
end

function API:deletePinnedChannelMessage(channel_id, message_id) -- Message:unpin
	local endpoint = f(endpoints.CHANNEL_PIN, channel_id, message_id)
	return self:request("DELETE", endpoint)
end

function API:groupDMAddRecipient(channel_id, user_id, payload) -- GroupChannel:addRecipient
	local endpoint = f(endpoints.CHANNEL_RECIPIENT, channel_id, user_id)
	return self:request("PUT", endpoint, payload)
end

function API:groupDMRemoveRecipient(channel_id, user_id) -- GroupChannel:removeRecipient
	local endpoint = f(endpoints.CHANNEL_RECIPIENT, channel_id, user_id)
	return self:request("DELETE", endpoint)
end

function API:createGuild(payload) -- Client:createGuild
	local endpoint = endpoints.GUILDS
	return self:request("POST", endpoint, payload)
end

function API:getGuild(guild_id) -- not exposed, use cache
	local endpoint = f(endpoints.GUILD, guild_id)
	return self:request("GET", endpoint)
end

function API:modifyGuild(guild_id, payload) -- Guild:_modify
	local endpoint = f(endpoints.GUILD, guild_id)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteGuild(guild_id) -- Guild:delete
	local endpoint = f(endpoints.GUILD, guild_id)
	return self:request("DELETE", endpoint)
end

function API:getGuildChannels(guild_id) -- not exposed, use cache
	local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
	return self:request("GET", endpoint)
end

function API:createGuildChannel(guild_id, payload) -- Guild:create[Text|Voice]Channel
	local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
	return self:request("POST", endpoint, payload)
end

function API:modifyGuildChannelPositions(guild_id, payload) -- TODO
	local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
	return self:request("PATCH", endpoint, payload)
end

function API:getGuildMember(guild_id, user_id) -- Guild:getMember fallback
	local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
	return self:request("GET", endpoint)
end

function API:listGuildMembers(guild_id) -- not exposed, use cache
	local endpoint = f(endpoints.GUILD_MEMBERS, guild_id)
	return self:request("GET", endpoint)
end

function API:addGuildMember(guild_id, user_id, payload) -- not exposed, limited use
	local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
	return self:request("PUT", endpoint, payload)
end

function API:modifyGuildMember(guild_id, user_id, payload) -- various Member methods
	local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
	return self:request("PATCH", endpoint, payload)
end

function API:modifyCurrentUsersNick(guild_id, payload) -- Member:setNickname
	local endpoint = f(endpoints.GUILD_MEMBER_ME_NICK, guild_id)
	return self:request("PATCH", endpoint, payload)
end

function API:addGuildMemberRole(guild_id, user_id, role_id, payload) -- Member:addrole
	local endpoint = f(endpoints.GUILD_MEMBER_ROLE, guild_id, user_id, role_id)
	return self:request("PUT", endpoint, payload)
end

function API:removeGuildMemberRole(guild_id, user_id, role_id) -- Member:removeRole
	local endpoint = f(endpoints.GUILD_MEMBER_ROLE, guild_id, user_id, role_id)
	return self:request("DELETE", endpoint)
end

function API:removeGuildMember(guild_id, user_id, query) -- Guild:kickUser
	local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
	return self:request("DELETE", endpoint, nil, query)
end

function API:getGuildBans(guild_id) -- Guild:getBans
	local endpoint = f(endpoints.GUILD_BANS, guild_id)
	return self:request("GET", endpoint)
end

function API:createGuildBan(guild_id, user_id, query) -- Guild:banUser
	local endpoint = f(endpoints.GUILD_BAN, guild_id, user_id)
	return self:request("PUT", endpoint, nil, query)
end

function API:removeGuildBan(guild_id, user_id, query) -- Guild:unbanUser
	local endpoint = f(endpoints.GUILD_BAN, guild_id, user_id)
	return self:request("DELETE", endpoint, nil, query)
end

function API:getGuildRoles(guild_id) -- not exposed, use cache
	local endpoint = f(endpoints.GUILD_ROLES, guild_id)
	return self:request("GET", endpoint)
end

function API:createGuildRole(guild_id, payload) -- Guild:createRole
	local endpoint = f(endpoints.GUILD_ROLES, guild_id)
	return self:request("POST", endpoint, payload)
end

function API:modifyGuildRolePositions(guild_id, payload) -- TODO
	local endpoint = f(endpoints.GUILD_ROLES, guild_id)
	return self:request("PATCH", endpoint, payload)
end

function API:modifyGuildRole(guild_id, role_id, payload) -- Role:_modify
	local endpoint = f(endpoints.GUILD_ROLE, guild_id, role_id)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildRole(guild_id, role_id) -- Role:delete
	local endpoint = f(endpoints.GUILD_ROLE, guild_id, role_id)
	return self:request("DELETE", endpoint)
end

function API:getGuildPruneCount(guild_id, query) -- Guild:getPruneCount
	local endpoint = f(endpoints.GUILD_PRUNE, guild_id)
	return self:request("GET", endpoint, nil, query)
end

function API:beginGuildPrune(guild_id, payload, query) -- Guild:pruneMembers
	local endpoint = f(endpoints.GUILD_PRUNE, guild_id)
	return self:request("POST", endpoint, payload, query)
end

function API:getGuildVoiceRegions(guild_id) -- Guild:listVoiceRegions
	local endpoint = f(endpoints.GUILD_REGIONS, guild_id)
	return self:request("GET", endpoint)
end

function API:getGuildInvites(guild_id) -- Guild:getInvites
	local endpoint = f(endpoints.GUILD_INVITES, guild_id)
	return self:request("GET", endpoint)
end

function API:getGuildIntegrations(guild_id) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_INTEGRATIONS, guild_id)
	return self:request("GET", endpoint)
end

function API:createGuildIntegration(guild_id, payload) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_INTEGRATIONS, guild_id)
	return self:request("POST", endpoint, payload)
end

function API:modifyGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_INTEGRATION, guild_id, integration_id)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildIntegration(guild_id, integration_id) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_INTEGRATION, guild_id, integration_id)
	return self:request("DELETE", endpoint)
end

function API:syncGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_INTEGRATION_SYNC, guild_id, integration_id)
	return self:request("POST", endpoint, payload)
end

function API:getGuildEmbed(guild_id) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_EMBED, guild_id)
	return self:request("GET", endpoint)
end

function API:modifyGuildEmbed(guild_id, payload) -- not exposed, maybe in the future
	local endpoint = f(endpoints.GUILD_EMBED, guild_id)
	return self:request("PATCH", endpoint, payload)
end

function API:getInvite(invite_code) -- Client:getInvite
	local endpoint = f(endpoints.INVITE, invite_code)
	return self:request("GET", endpoint)
end

function API:deleteInvite(invite_code) -- Invite:delete
	local endpoint = f(endpoints.INVITE, invite_code)
	return self:request("DELETE", endpoint)
end

function API:acceptInvite(invite_code, payload) -- not exposed, invalidates tokens
	local endpoint = f(endpoints.INVITE, invite_code)
	return self:request("POST", endpoint, payload)
end

function API:getCurrentUser() -- API:authenticate
	local endpoint = endpoints.USER_ME
	return self:request("GET", endpoint)
end

function API:getUser(user_id) -- Client:getUser
	local endpoint = f(endpoints.USER, user_id)
	return self:request("GET", endpoint)
end

function API:modifyCurrentUser(payload) -- Client:_modify
	local endpoint = endpoints.USER_ME
	return self:request("PATCH", endpoint, payload)
end

function API:getCurrentUserGuilds() -- not exposed, use cache
	local endpoint = endpoints.USER_ME_GUILDS
	return self:request("GET", endpoint)
end

function API:leaveGuild(guild_id) -- Guild:leave
	local endpoint = f(endpoints.USER_ME_GUILD, guild_id)
	return self:request("DELETE", endpoint)
end

function API:getUserDMs() -- not exposed, use cache
	local endpoint = endpoints.USER_ME_CHANNELS
	return self:request("GET", endpoint)
end

function API:createDM(payload) -- User:getPrivateChannel fallback
	local endpoint = endpoints.USER_ME_CHANNELS
	return self:request("POST", endpoint, payload)
end

function API:createGroupDM(payload)
	local endpoint = endpoints.USER_ME_CHANNELS
	return self:request("POST", endpoint, payload)
end

function API:getUsersConnections() -- Client:getConnections
	local endpoint = endpoints.USER_ME_CONNECTIONS
	return self:request("GET", endpoint)
end

function API:listVoiceRegions() -- Client:listVoiceRegions
	local endpoint = endpoints.VOICE_REGIONS
	return self:request("GET", endpoint)
end

function API:createWebhook(channel_id, payload) -- GuildTextChannel:createWebhook
	local endpoint = f(endpoints.CHANNEL_WEBHOOKS, channel_id)
	return self:request("POST", endpoint, payload)
end

function API:getChannelWebhooks(channel_id) -- GuildTextChannel:getWebhooks
	local endpoint = f(endpoints.CHANNEL_WEBHOOKS, channel_id)
	return self:request("GET", endpoint)
end

function API:getGuildWebhooks(guild_id) -- Guild:getWebhooks
	local endpoint = f(endpoints.GUILD_WEBHOOKS, guild_id)
	return self:request("GET", endpoint)
end

function API:getWebhook(webhook_id) -- Client:getWebhook
	local endpoint = f(endpoints.WEBHOOK, webhook_id)
	return self:request("GET", endpoint)
end

function API:getWebhookWithToken(webhook_id, webhook_token) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
	return self:request("GET", endpoint)
end

function API:modifyWebhook(webhook_id, payload) -- Webhook:_modify
	local endpoint = f(endpoints.WEBHOOK, webhook_id)
	return self:request("PATCH", endpoint, payload)
end

function API:modifyWebhookWithToken(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
	return self:request("PATCH", endpoint, payload)
end

function API:deleteWebhook(webhook_id) -- Webhook:delete
	local endpoint = f(endpoints.WEBHOOK, webhook_id)
	return self:request("DELETE", endpoint)
end

function API:deleteWebhookWithToken(webhook_id, webhook_token) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
	return self:request("DELETE", endpoint)
end

function API:executeWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
	return self:request("POST", endpoint, payload)
end

function API:executeSlackCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN_SLACK, webhook_id, webhook_token)
	return self:request("POST", endpoint, payload)
end

function API:executeGitHubCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
	local endpoint = f(endpoints.WEBHOOK_TOKEN_GITHUB, webhook_id, webhook_token)
	return self:request("POST", endpoint, payload)
end

function API:getGateway() -- Client:run
	local endpoint = endpoints.GATEWAY
	return self:request("GET", endpoint)
end

function API:getGatewayBot() -- Client:run
	local endpoint = endpoints.GATEWAY_BOT
	return self:request("GET", endpoint)
end

function API:getCurrentApplicationInformation() -- Client:run
	local endpoint = endpoints.OAUTH2_APPLICATION_ME
	return self:request("GET", endpoint)
end

-- end of auto-generated methods --

return API
