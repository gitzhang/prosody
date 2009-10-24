-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local datamanager = require "util.datamanager";
local datetime = require "util.datetime";

local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local multitable_new = require "util.multitable".new;
local t_insert, t_remove = table.insert, table.remove;
local setmetatable = setmetatable;
local base64 = require "util.encodings".base64;
local md5 = require "util.hashes".md5;

local muc_domain = nil; --module:get_host();
local history_length = 20;

------------
local function filter_xmlns_from_array(array, filters)
	local count = 0;
	for i=#array,1,-1 do
		local attr = array[i].attr;
		if filters[attr and attr.xmlns] then
			t_remove(array, i);
			count = count + 1;
		end
	end
	return count;
end
local function filter_xmlns_from_stanza(stanza, filters)
	if filters then
		if filter_xmlns_from_array(stanza.tags, filters) ~= 0 then
			return stanza, filter_xmlns_from_array(stanza, filters);
		end
	end
	return stanza, 0;
end
local presence_filters = {["http://jabber.org/protocol/muc"]=true;["http://jabber.org/protocol/muc#user"]=true};
local function get_filtered_presence(stanza)
	return filter_xmlns_from_stanza(st.clone(stanza):reset(), presence_filters);
end
local kickable_error_conditions = {
	["gone"] = true;
	["internal-server-error"] = true;
	["item-not-found"] = true;
	["jid-malformed"] = true;
	["recipient-unavailable"] = true;
	["redirect"] = true;
	["remote-server-not-found"] = true;
	["remote-server-timeout"] = true;
	["service-unavailable"] = true;
	["malformed error"] = true;
};
local function get_error_condition(stanza)
	for _, tag in ipairs(stanza.tags) do
		if tag.name == "error" and (not(tag.attr.xmlns) or tag.attr.xmlns == "jabber:client") then
			for _, cond in ipairs(tag.tags) do
				if cond.attr.xmlns == "urn:ietf:params:xml:ns:xmpp-stanzas" then
					return cond.name;
				end
			end
			return "malformed error";
		end
	end
	return "malformed error";
end
local function is_kickable_error(stanza)
	local cond = get_error_condition(stanza);
	return kickable_error_conditions[cond] and cond;
end
local function getUsingPath(stanza, path, getText)
	local tag = stanza;
	for _, name in ipairs(path) do
		if type(tag) ~= 'table' then return; end
		tag = tag:child_with_name(name);
	end
	if tag and getText then tag = table.concat(tag); end
	return tag;
end
local function getTag(stanza, path) return getUsingPath(stanza, path); end
local function getText(stanza, path) return getUsingPath(stanza, path, true); end
-----------

--[[function get_room_disco_info(room, stanza)
	return st.iq({type='result', id=stanza.attr.id, from=stanza.attr.to, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='conference', type='text', name=room._data["name"]):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}); -- TODO cache disco reply
end
function get_room_disco_items(room, stanza)
	return st.iq({type='result', id=stanza.attr.id, from=stanza.attr.to, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#items");
end -- TODO allow non-private rooms]]

--

local room_mt = {};
room_mt.__index = room_mt;

function room_mt:get_default_role(affiliation)
	if affiliation == "owner" or affiliation == "admin" then
		return "moderator";
	elseif affiliation == "member" or not affiliation then
		return "participant";
	end
end

function room_mt:broadcast_presence(stanza, sid, code, nick)
	stanza = get_filtered_presence(stanza);
	local occupant = self._occupants[stanza.attr.from];
	stanza:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
		:tag("item", {affiliation=occupant.affiliation, role=occupant.role, nick=nick}):up();
	if code then
		stanza:tag("status", {code=code}):up();
	end
	self:broadcast_except_nick(stanza, stanza.attr.from);
	local me = self._occupants[stanza.attr.from];
	if me then
		stanza:tag("status", {code='110'});
		stanza.attr.to = sid;
		self:route_stanza(stanza);
	end
end
function room_mt:broadcast_message(stanza, historic)
	for occupant, o_data in pairs(self._occupants) do
		for jid in pairs(o_data.sessions) do
			stanza.attr.to = jid;
			self:route_stanza(stanza);
		end
	end
	if historic then -- add to history
		local history = self._data['history'];
		if not history then history = {}; self._data['history'] = history; end
		-- stanza = st.clone(stanza);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = muc_domain, stamp = datetime.datetime()}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = muc_domain, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
		t_insert(history, st.clone(st.preserialize(stanza)));
		while #history > history_length do t_remove(history, 1) end
	end
end
function room_mt:broadcast_except_nick(stanza, nick)
	for rnick, occupant in pairs(self._occupants) do
		if rnick ~= nick then
			for jid in pairs(occupant.sessions) do
				stanza.attr.to = jid;
				self:route_stanza(stanza);
			end
		end
	end
end

function room_mt:send_occupant_list(to)
	local current_nick = self._jid_nick[to];
	for occupant, o_data in pairs(self._occupants) do
		if occupant ~= current_nick then
			local pres = get_filtered_presence(o_data.sessions[o_data.jid]);
			pres.attr.to, pres.attr.from = to, occupant;
			pres:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
				:tag("item", {affiliation=o_data.affiliation, role=o_data.role}):up();
			self:route_stanza(pres);
		end
	end
end
function room_mt:send_history(to)
	local history = self._data['history']; -- send discussion history
	if history then
		for _, msg in ipairs(history) do
			msg = st.deserialize(msg);
			msg.attr.to=to;
			self:route_stanza(msg);
		end
	end
	if self._data['subject'] then
		self:route_stanza(st.message({type='groupchat', from=self.jid, to=to}):tag("subject"):text(self._data['subject']));
	end
end

local function room_get_disco_info(self, stanza)
	return st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category="conference", type="text"}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"});
end
local function room_get_disco_items(self, stanza)
	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for room_jid in pairs(self._occupants) do
		reply:tag("item", {jid = room_jid, name = room_jid:match("/(.*)")}):up();
	end
	return reply;
end
function room_mt:set_subject(current_nick, subject)
	-- TODO check nick's authority
	if subject == "" then subject = nil; end
	self._data['subject'] = subject;
	if self.save then self:save(); end
	local msg = st.message({type='groupchat', from=current_nick})
		:tag('subject'):text(subject):up();
	self:broadcast_message(msg, false);
	return true;
end

function room_mt:handle_to_occupant(origin, stanza) -- PM, vCards, etc
	local from, to = stanza.attr.from, stanza.attr.to;
	local room = jid_bare(to);
	local current_nick = self._jid_nick[from];
	local type = stanza.attr.type;
	log("debug", "room: %s, current_nick: %s, stanza: %s", room or "nil", current_nick or "nil", stanza:top_tag());
	if (select(2, jid_split(from)) == muc_domain) then error("Presence from the MUC itself!!!"); end
	if stanza.name == "presence" then
		local pr = get_filtered_presence(stanza);
		pr.attr.from = current_nick;
		if type == "error" then -- error, kick em out!
			if current_nick then
				log("debug", "kicking %s from %s", current_nick, room);
				self:handle_to_occupant(origin, st.presence({type='unavailable', from=from, to=to})
					:tag('status'):text('Kicked: '..get_error_condition(stanza))); -- send unavailable
			end
		elseif type == "unavailable" then -- unavailable
			if current_nick then
				log("debug", "%s leaving %s", current_nick, room);
				local occupant = self._occupants[current_nick];
				local new_jid = next(occupant.sessions);
				if new_jid == from then new_jid = next(occupant.sessions, new_jid); end
				if new_jid then
					local jid = occupant.jid;
					occupant.jid = new_jid;
					occupant.sessions[from] = nil;
					pr.attr.to = from;
					pr:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
						:tag("item", {affiliation=occupant.affiliation, role='none'}):up()
						:tag("status", {code='110'});
					self:route_stanza(pr);
					if jid ~= new_jid then
						pr = st.clone(occupant.sessions[new_jid])
							:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
							:tag("item", {affiliation=occupant.affiliation, role=occupant.role});
						pr.attr.from = current_nick;
						self:broadcast_except_nick(pr, current_nick);
					end
				else
					occupant.role = 'none';
					self:broadcast_presence(pr, from);
					self._occupants[current_nick] = nil;
				end
				self._jid_nick[from] = nil;
			end
		elseif not type then -- available
			if current_nick then
				--if #pr == #stanza or current_nick ~= to then -- commented because google keeps resending directed presence
					if current_nick == to then -- simple presence
						log("debug", "%s broadcasted presence", current_nick);
						self._occupants[current_nick].sessions[from] = pr;
						self:broadcast_presence(pr, from);
					else -- change nick
						local occupant = self._occupants[current_nick];
						local is_multisession = next(occupant.sessions, next(occupant.sessions));
						if self._occupants[to] or is_multisession then
							log("debug", "%s couldn't change nick", current_nick);
							local reply = st.error_reply(stanza, "cancel", "conflict"):up();
							reply.tags[1].attr.code = "409";
							origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
						else
							local data = self._occupants[current_nick];
							local to_nick = select(3, jid_split(to));
							if to_nick then
								log("debug", "%s (%s) changing nick to %s", current_nick, data.jid, to);
								local p = st.presence({type='unavailable', from=current_nick});
								self:broadcast_presence(p, from, '303', to_nick);
								self._occupants[current_nick] = nil;
								self._occupants[to] = data;
								self._jid_nick[from] = to;
								pr.attr.from = to;
								self._occupants[to].sessions[from] = pr;
								self:broadcast_presence(pr, from);
							else
								--TODO malformed-jid
							end
						end
					end
				--else -- possible rejoin
				--	log("debug", "%s had connection replaced", current_nick);
				--	self:handle_to_occupant(origin, st.presence({type='unavailable', from=from, to=to})
				--		:tag('status'):text('Replaced by new connection'):up()); -- send unavailable
				--	self:handle_to_occupant(origin, stanza); -- resend available
				--end
			else -- enter room
				local new_nick = to;
				local is_merge;
				if self._occupants[to] then
					if jid_bare(from) ~= jid_bare(self._occupants[to].jid) then
						new_nick = nil;
					end
					is_merge = true;
				end
				if not new_nick then
					log("debug", "%s couldn't join due to nick conflict: %s", from, to);
					local reply = st.error_reply(stanza, "cancel", "conflict"):up();
					reply.tags[1].attr.code = "409";
					origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				else
					log("debug", "%s joining as %s", from, to);
					if not next(self._affiliations) then -- new room, no owners
						self._affiliations[jid_bare(from)] = "owner";
					end
					local affiliation = self:get_affiliation(from);
					local role = self:get_default_role(affiliation)
					if role then -- new occupant
						if not is_merge then
							self._occupants[to] = {affiliation=affiliation, role=role, jid=from, sessions={[from]=get_filtered_presence(stanza)}};
						else
							self._occupants[to].sessions[from] = get_filtered_presence(stanza);
						end
						self._jid_nick[from] = to;
						self:send_occupant_list(from);
						pr.attr.from = to;
						if not is_merge then
							self:broadcast_presence(pr, from);
						else
							pr.attr.to = from;
							self:route_stanza(pr:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
								:tag("item", {affiliation=affiliation, role=role}):up()
								:tag("status", {code='110'}));
						end
						self:send_history(from);
					else -- banned
						local reply = st.error_reply(stanza, "auth", "forbidden"):up();
						reply.tags[1].attr.code = "403";
						origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
					end
				end
			end
		elseif type ~= 'result' then -- bad type
			if type ~= 'visible' and type ~= 'invisible' then -- COMPAT ejabberd can broadcast or forward XEP-0018 presences
				origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
			end
		end
	elseif not current_nick then -- not in room
		if type == "error" or type == "result" then
			local id = stanza.name == "iq" and stanza.attr.id and base64.decode(stanza.attr.id);
			local _nick, _id, _hash = (id or ""):match("^(.+)%z(.*)%z(.+)$");
			local occupant = self._occupants[stanza.attr.to];
			if occupant and _nick and self._jid_nick[_nick] and _id and _hash then
				local id, _to = stanza.attr.id;
				for jid in pairs(occupant.sessions) do
					if md5(jid) == _hash then
						_to = jid;
						break;
					end
				end
				if _to then
					stanza.attr.to, stanza.attr.from, stanza.attr.id = _to, self._jid_nick[_nick], _id;
					self:route_stanza(stanza);
					stanza.attr.to, stanza.attr.from, stanza.attr.id = to, from, id;
				end
			end
		else
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then -- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	elseif current_nick and stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		self:handle_to_occupant(origin, st.presence({type='unavailable', from=stanza.attr.from, to=stanza.attr.to})
			:tag('status'):text('Kicked: '..get_error_condition(stanza))); -- send unavailable
	else -- private stanza
		local o_data = self._occupants[to];
		if o_data then
			log("debug", "%s sent private stanza to %s (%s)", from, to, o_data.jid);
			local jid = o_data.jid;
			local bare = jid_bare(jid);
			stanza.attr.to, stanza.attr.from = jid, current_nick;
			local id = stanza.attr.id;
			if stanza.name=='iq' and type=='get' and stanza.tags[1].attr.xmlns == 'vcard-temp' and bare ~= jid then
				stanza.attr.to = bare;
				stanza.attr.id = base64.encode(jid.."\0"..id.."\0"..md5(from));
			end
			self:route_stanza(stanza);
			stanza.attr.to, stanza.attr.from, stanza.attr.id = to, from, id;
		elseif type ~= "error" and type ~= "result" then -- recipient not in room
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
		end
	end
end

function room_mt:handle_form(origin, stanza)
	if self:get_affiliation(stanza.attr.from) ~= "owner" then origin.send(st.error_reply(stanza, "auth", "forbidden")); return; end
	if stanza.attr.type == "get" then
		local title = "Configuration for "..self.jid;
		origin.send(st.reply(stanza):query("http://jabber.org/protocol/muc#owner")
			:tag("x", {xmlns='jabber:x:data', type='form'})
				:tag("title"):text(title):up()
				:tag("instructions"):text(title):up()
				:tag("field", {type='hidden', var='FORM_TYPE'}):tag("value"):text("http://jabber.org/protocol/muc#roomconfig"):up():up()
				:tag("field", {type='boolean', label='Make Room Persistent?', var='muc#roomconfig_persistentroom'})
					:tag("value"):text(self._data.persistent and "1" or "0"):up()
				:up()
				:tag("field", {type='boolean', label='Make Room Publicly Searchable?', var='muc#roomconfig_publicroom'})
					:tag("value"):text(self._data.hidden and "0" or "1"):up()
				:up()
		);
	elseif stanza.attr.type == "set" then
		local query = stanza.tags[1];
		local form;
		for _, tag in ipairs(query.tags) do if tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then form = tag; break; end end
		if not form then origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); return; end
		if form.attr.type == "cancel" then origin.send(st.reply(stanza)); return; end
		if form.attr.type ~= "submit" then origin.send(st.error_reply(stanza, "cancel", "bad-request")); return; end
		local fields = {};
		for _, field in pairs(form.tags) do
			if field.name == "field" and field.attr.var and field.tags[1].name == "value" and #field.tags[1].tags == 0 then
				fields[field.attr.var] = field.tags[1][1] or "";
			end
		end
		if fields.FORM_TYPE ~= "http://jabber.org/protocol/muc#roomconfig" then origin.send(st.error_reply(stanza, "cancel", "bad-request")); return; end

		local persistent = fields['muc#roomconfig_persistentroom'];
		if persistent == "0" or persistent == "false" then persistent = nil; elseif persistent == "1" or persistent == "true" then persistent = true;
		else origin.send(st.error_reply(stanza, "cancel", "bad-request")); return; end
		self._data.persistent = persistent;
		module:log("debug", "persistent=%s", tostring(persistent));

		local public = fields['muc#roomconfig_publicroom'];
		if public == "0" or public == "false" then public = nil; elseif public == "1" or public == "true" then public = true;
		else origin.send(st.error_reply(stanza, "cancel", "bad-request")); return; end
		self._data.hidden = not public and true or nil;

		if self.save then self:save(true); end
		origin.send(st.reply(stanza));
	end
end

function room_mt:handle_to_room(origin, stanza) -- presence changes and groupchat messages, along with disco/etc
	local type = stanza.attr.type;
	local xmlns = stanza.tags[1] and stanza.tags[1].attr.xmlns;
	if stanza.name == "iq" then
		if xmlns == "http://jabber.org/protocol/disco#info" and type == "get" then
			origin.send(room_get_disco_info(self, stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" and type == "get" then
			origin.send(room_get_disco_items(self, stanza));
		elseif xmlns == "http://jabber.org/protocol/muc#admin" then
			local actor = stanza.attr.from;
			local affiliation = self:get_affiliation(actor);
			local current_nick = self._jid_nick[actor];
			local role = current_nick and self._occupants[current_nick].role or self:get_default_role(affiliation);
			local item = stanza.tags[1].tags[1];
			if item and item.name == "item" then
				if type == "set" then
					local callback = function() origin.send(st.reply(stanza)); end
					if item.attr.jid then -- Validate provided JID
						item.attr.jid = jid_prep(item.attr.jid);
						if not item.attr.jid then
							origin.send(st.error_reply(stanza, "modify", "jid-malformed"));
							return;
						end
					end
					if not item.attr.jid and item.attr.nick then -- COMPAT Workaround for Miranda sending 'nick' instead of 'jid' when changing affiliation
						local occupant = self._occupants[self.jid.."/"..item.attr.nick];
						if occupant then item.attr.jid = occupant.jid; end
					end
					local reason = item.tags[1] and item.tags[1].name == "reason" and #item.tags[1] == 1 and item.tags[1][1];
					if item.attr.affiliation and item.attr.jid and not item.attr.role then
						local success, errtype, err = self:set_affiliation(actor, item.attr.jid, item.attr.affiliation, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					elseif item.attr.role and item.attr.nick and not item.attr.affiliation then
						local success, errtype, err = self:set_role(actor, self.jid.."/"..item.attr.nick, item.attr.role, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				elseif type == "get" then
					local _aff = item.attr.affiliation;
					local _rol = item.attr.role;
					if _aff and not _rol then
						if affiliation == "owner" or (affiliation == "admin" and _aff ~= "owner" and _aff ~= "admin") then
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for jid, affiliation in pairs(self._affiliations) do
								if affiliation == _aff then
									reply:tag("item", {affiliation = _aff, jid = jid}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					elseif _rol and not _aff then
						if role == "moderator" then
							-- TODO allow admins and owners not in room? Provide read-only access to everyone who can see the participants anyway?
							if _rol == "none" then _rol = nil; end
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for nick, occupant in pairs(self._occupants) do
								if occupant.role == _rol then
									reply:tag("item", {nick = nick, role = _rol or "none", affiliation = occupant.affiliation or "none", jid = occupant.jid}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				end
			elseif type == "set" or type == "get" then
				origin.send(st.error_reply(stanza, "cancel", "bad-request"));
			end
		elseif xmlns == "http://jabber.org/protocol/muc#owner" and (type == "get" or type == "set") and stanza.tags[1].name == "query" then
			self:handle_form(origin, stanza);
		elseif type == "set" or type == "get" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then
		local from, to = stanza.attr.from, stanza.attr.to;
		local room = jid_bare(to);
		local current_nick = self._jid_nick[from];
		if not current_nick then -- not in room
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		else
			local from = stanza.attr.from;
			stanza.attr.from = current_nick;
			local subject = getText(stanza, {"subject"});
			if subject then
				self:set_subject(current_nick, subject); -- TODO use broadcast_message_stanza
			else
				self:broadcast_message(stanza, true);
			end
		end
	elseif stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		local current_nick = self._jid_nick[stanza.attr.from];
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		self:handle_to_occupant(origin, st.presence({type='unavailable', from=stanza.attr.from, to=stanza.attr.to})
			:tag('status'):text('Kicked: '..get_error_condition(stanza))); -- send unavailable
	elseif stanza.name == "presence" then -- hack - some buggy clients send presence updates to the room rather than their nick
		local to = stanza.attr.to;
		local current_nick = self._jid_nick[stanza.attr.from];
		if current_nick then
			stanza.attr.to = current_nick;
			self:handle_to_occupant(origin, stanza);
			stanza.attr.to = to;
		elseif type ~= "error" and type ~= "result" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and not stanza.attr.type and #stanza.tags == 1 and self._jid_nick[stanza.attr.from]
		and stanza.tags[1].name == "x" and stanza.tags[1].attr.xmlns == "http://jabber.org/protocol/muc#user" then
		local x = stanza.tags[1];
		local payload = (#x.tags == 1 and x.tags[1]);
		if payload and payload.name == "invite" and payload.attr.to then
			local _from, _to = stanza.attr.from, stanza.attr.to;
			local _invitee = jid_prep(payload.attr.to);
			if _invitee then
				local _reason = payload.tags[1] and payload.tags[1].name == 'reason' and #payload.tags[1].tags == 0 and payload.tags[1][1];
				local invite = st.message({from = _to, to = _invitee, id = stanza.attr.id})
					:tag('x', {xmlns='http://jabber.org/protocol/muc#user'})
						:tag('invite', {from=_from})
							:tag('reason'):text(_reason or ""):up()
						:up()
					:up()
					:tag('x', {xmlns="jabber:x:conference", jid=_to}) -- COMPAT: Some older clients expect this
						:text(_reason or "")
					:up()
					:tag('body') -- Add a plain message for clients which don't support invites
						:text(_from..' invited you to the room '.._to..(_reason and (' ('.._reason..')') or ""))
					:up();
				self:route_stanza(invite);
			else
				origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
			end
		else
			origin.send(st.error_reply(stanza, "cancel", "bad-request"));
		end
	else
		if type == "error" or type == "result" then return; end
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end
end

function room_mt:handle_stanza(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	if to_resource then
		self:handle_to_occupant(origin, stanza);
	else
		self:handle_to_room(origin, stanza);
	end
end

function room_mt:route_stanza(stanza) end -- Replace with a routing function, e.g., function(room, stanza) core_route_stanza(origin, stanza); end

function room_mt:get_affiliation(jid)
	local node, host, resource = jid_split(jid);
	local bare = node and node.."@"..host or host;
	local result = self._affiliations[bare]; -- Affiliations are granted, revoked, and maintained based on the user's bare JID.
	if not result and self._affiliations[host] == "outcast" then result = "outcast"; end -- host banned
	return result;
end
function room_mt:set_affiliation(actor, jid, affiliation, callback, reason)
	jid = jid_bare(jid);
	if affiliation == "none" then affiliation = nil; end
	if affiliation and affiliation ~= "outcast" and affiliation ~= "owner" and affiliation ~= "admin" and affiliation ~= "member" then
		return nil, "modify", "not-acceptable";
	end
	if self:get_affiliation(actor) ~= "owner" then return nil, "cancel", "not-allowed"; end
	if jid_bare(actor) == jid then return nil, "cancel", "not-allowed"; end
	self._affiliations[jid] = affiliation;
	local role = self:get_default_role(affiliation);
	local p = st.presence()
		:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=affiliation or "none", role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	local x = p.tags[1];
	local item = x.tags[1];
	if not role then -- getting kicked
		p.attr.type = "unavailable";
		if affiliation == "outcast" then
			x:tag("status", {code="301"}):up(); -- banned
		else
			x:tag("status", {code="321"}):up(); -- affiliation change
		end
	end
	local modified_nicks = {};
	for nick, occupant in pairs(self._occupants) do
		if jid_bare(occupant.jid) == jid then
			if not role then -- getting kicked
				self._occupants[nick] = nil;
			else
				t_insert(modified_nicks, nick);
				occupant.affiliation, occupant.role = affiliation, role;
			end
			p.attr.from = nick;
			for jid in pairs(occupant.sessions) do -- remove for all sessions of the nick
				if not role then self._jid_nick[jid] = nil; end
				p.attr.to = jid;
				self:route_stanza(p);
			end
		end
	end
	if self.save then self:save(); end
	if callback then callback(); end
	for _, nick in ipairs(modified_nicks) do
		p.attr.from = nick;
		self:broadcast_except_nick(p, nick);
	end
	return true;
end

function room_mt:get_role(nick)
	local session = self._occupants[nick];
	return session and session.role or nil;
end
function room_mt:set_role(actor, nick, role, callback, reason)
	if role == "none" then role = nil; end
	if role and role ~= "moderator" and role ~= "participant" and role ~= "visitor" then return nil, "modify", "not-acceptable"; end
	if self:get_affiliation(actor) ~= "owner" then return nil, "cancel", "not-allowed"; end
	local occupant = self._occupants[nick];
	if not occupant then return nil, "modify", "not-acceptable"; end
	if occupant.affiliation == "owner" or occupant.affiliation == "admin" then return nil, "cancel", "not-allowed"; end
	local p = st.presence({from = nick})
		:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=occupant.affiliation or "none", nick=nick, role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	if not role then -- kick
		p.attr.type = "unavailable";
		self._occupants[nick] = nil;
		for jid in pairs(occupant.sessions) do -- remove for all sessions of the nick
			self._jid_nick[jid] = nil;
		end
		p:tag("status", {code = "307"}):up();
	else
		occupant.role = role;
	end
	for jid in pairs(occupant.sessions) do -- send to all sessions of the nick
		p.attr.to = jid;
		self:route_stanza(p);
	end
	if callback then callback(); end
	self:broadcast_except_nick(p, nick);
	return true;
end

local _M = {}; -- module "muc"

function _M.new_room(jid)
	return setmetatable({
		jid = jid;
		_jid_nick = {};
		_occupants = {};
		_data = {};
		_affiliations = {};
	}, room_mt);
end

return _M;
