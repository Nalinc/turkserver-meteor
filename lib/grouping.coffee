###
  SERVER METHODS
  Hook in group id to all operations, including find

  Grouping contains _id: userId and groupId: groupId
###

@Grouping = new Meteor.Collection("ts.grouping")

# Meteor environment variables for scoping group operations
TurkServer._currentGroup = new Meteor.EnvironmentVariable()
TurkServer._directOps = new Meteor.EnvironmentVariable()

class TurkServer.Groups
  @setUserGroup = (userId, groupId) ->
    check(userId, String)
    check(groupId, String)
    if Grouping.findOne(userId)
      throw new Meteor.Error(403, "User is already in a group")

    Grouping.upsert userId,
      $set: {groupId: groupId}

  @getUserGroup = (userId) ->
    check(userId, String)
    Grouping.findOne(userId)?.groupId

  @clearUserGroup = (userId) ->
    check(userId, String)
    Grouping.remove(userId)

TurkServer.group = ->
  userId = Meteor.userId()
  return unless userId
  return TurkServer.Groups.getUserGroup(userId)

TurkServer.bindGroup = (groupId, func) ->
  TurkServer._currentGroup.withValue(groupId, func);

TurkServer.bindUserGroup = (userId, func) ->
  groupId = TurkServer.Groups.getUserGroup(userId)
  unless groupId
    Meteor.debug "Dropping operation because #{userId} is not in a group"
    return
  TurkServer.bindGroup(groupId, func)

TurkServer.directOperation = (func) ->
  TurkServer._directOps.withValue(true, func);

alwaysTrue = -> true

TurkServer._getPartitionedIndex = (index) ->
  defaultIndex = { _groupId : 1 }
  return defaultIndex unless index
  return _.extend( defaultIndex, index )

TurkServer.partitionCollection = (collection, options) ->
  # Because of below, need to create an allow validator if there isn't one already
  if collection._isInsecure
    collection.allow
      insert: alwaysTrue
      update: alwaysTrue
      remove: alwaysTrue

  # Idiot-proof the collection against admin users
  # TurkServer.isAdmin defined in turkserver.coffee
  collection.deny
    insert: TurkServer.isAdminRule
    update: TurkServer.isAdminRule
    remove: TurkServer.isAdminRule

  collection.before.find findHook
  collection.before.findOne findHook

  # These will hook the _validated methods as well
  collection.before.insert insertHook

  ###
    No update/remove hook necessary, see
    https://github.com/matb33/meteor-collection-hooks/issues/23
  ###

  # Index the collections by groupId on the server for faster lookups...?
  # TODO figure out how compound indices work on Mongo and if we should do something smarter
  collection._ensureIndex TurkServer._getPartitionedIndex(options?.index)

###
  Publish a user's group to the config collection - much better than keeping it in the user.

  NOTE: this is important as it generates all of the other necessary data.
####
Meteor.publish null, ->
  return unless @userId
  sub = this
  subHandle = Grouping.find(@userId, { fields: {groupId: 1} }).observeChanges
    added: (id, fields) ->
      sub.added "ts.config", "groupId", { value: fields.groupId }
    changed: (id, fields) ->
      sub.changed "ts.config", "groupId", { value: fields.groupId }
    removed: (id) ->
      sub.removed "ts.config", "groupId"
  sub.ready()
  sub.onStop -> subHandle.stop()

# Sync grouping to turkserver.group, needed for hooking Meteor.users
Meteor.startup ->
  Grouping.find().observeChanges
    added: (id, fields) ->
      Meteor.users.upsert(id, $set: {"turkserver.group": fields.groupId} )
    changed: (id, fields) ->
      Meteor.users.upsert(id, $set: {"turkserver.group": fields.groupId} )
    removed: (id) ->
      Meteor.users.upsert(id, $unset: {"turkserver.group": null} )

TurkServer.groupingHooks = {}

# Special hook for Meteor.users to scope for each group
userFindHook = (userId, selector, options) ->
  return true if TurkServer._directOps.get() is true
  return true if _.isString(selector) or
    (selector? and ("_id" of selector or "username" of selector))

  groupId = TurkServer._currentGroup.get()
  # Do the usual find for no user/group or single selector
  return true if (!userId and !groupId)

  unless groupId
    user = Meteor.users.findOne(userId)
    groupId = Grouping.findOne(userId)?.groupId
    # If user is admin and not in a group, proceed as normal (select all users)
    return true if user.admin and !groupId
    # Normal users need to be in a group
    throw new Meteor.Error(403, ErrMsg.groupErr) unless groupId

  # Since user is in a group, scope the find to the group
  unless @args[0]
    @args[0] =
      "turkserver.group" : groupId
      "admin": {$exists: false}
  else
    selector["turkserver.group"] = groupId
    selector.admin = {$exists: false}

  return true

TurkServer.groupingHooks.userFindHook = userFindHook

# Attach the find hooks to Meteor.users
Meteor.startup ->
  Meteor.users.before.find userFindHook
  Meteor.users.before.findOne userFindHook

# No allow/deny for find so we make our own checks
findHook = (userId, selector, options) ->
  # Don't scope for direct operations
  return true if TurkServer._directOps.get() is true

  # for find(id) we should not touch this
  # TODO may allow arbitrary finds
  return true if _.isString(selector) or (selector? and "_id" of selector)

  # Check for global hook
  groupId = TurkServer._currentGroup.get()
  unless groupId
    throw new Meteor.Error(403, ErrMsg.userIdErr) unless userId
    groupId = Grouping.findOne(userId)?.groupId
    throw new Meteor.Error(403, ErrMsg.groupErr) unless groupId

  # if object (or empty) selector, just filter by group
  unless @args[0]
    @args[0] = { _groupId : groupId }
  else
    selector._groupId = groupId
  return true

insertHook = (userId, doc) ->
  # Don't add group for direct inserts
  return true if TurkServer._directOps.get() is true

  groupId = TurkServer._currentGroup.get()
  unless groupId
    throw new Meteor.Error(403, ErrMsg.userIdErr) unless userId
    groupId = Grouping.findOne(userId)?.groupId
    throw new Meteor.Error(403, ErrMsg.groupErr) unless groupId

  doc._groupId = groupId
  return true

TurkServer.groupingHooks.findHook = findHook
TurkServer.groupingHooks.insertHook = insertHook

