_ = require 'underscore'
request = require 'request'
{EventEmitter} = require 'events'

{NSQDConnection} = require './nsqdconnection'
{ReaderRdy} = require './readerrdy'
RoundRobinList = require './roundrobinlist'
lookup = require './lookupd'


class Reader extends EventEmitter

  # Responsibilities
  # 1. Responsible for periodically querying the nsqlookupds
  # 2. Connects and subscribes to discovered/configured nsqd
  # 3. Consumes messages and triggers MESSAGE events
  # 4. Starts the ReaderRdy instance
  # 5. Hands nsqd connections to the ReaderRdy instance
  # 6. Stores Reader configurations

  # Reader events
  @ERROR: 'error'
  @MESSAGE: 'message'
  @DISCARD: 'discard'
  @NSQD_CONNECTED: 'nsqd_connected'
  @NSQD_CLOSED: 'nsqd_closed'

  constructor: (@topic, @channel, options) ->
    defaults =
      name: null
      maxInFlight: 1
      heartbeatInterval: 30
      maxBackoffDuration: 128
      maxAttempts: 5
      requeueDelay: 90
      nsqdTCPAddresses: []
      lookupdHTTPAddresses: []
      lookupdPollInterval: 60
      lookupdPollJitter: 0.3

    params = _.extend {}, defaults, options

    unless _.isString(topic) and topic.length > 0
      throw new Error 'Invalid topic'
    unless _.isNumber(params.maxInFlight) and params.maxInFlight > 0
      throw new Error 'maxInFlight needs to be an integer greater than 0'
    unless _.isNumber(params.heartbeatInterval) and params.heartbeatInterval > 0
      throw new Error 'heartbeatInterval needs to be an integer greater than 1'
    unless _.isNumber params.maxBackoffDuration
      throw new Error 'maxBackoffDuration needs to be a number'
    unless params.maxBackoffDuration > 0
      throw new Error 'maxBackoffDuration needs to be a number greater than 1'
    unless params.name is null or _.isString params.name
      throw new Error 'name needs to be unspecified or a string'
    unless _.isNumber params.lookupdPollInterval
      throw new Error 'lookupdPollInterval needs to be a number'
    unless 0 <= params.lookupdPollInterval
      throw new Error 'lookupdPollInterval needs to be greater than 0'
    unless _.isNumber params.lookupdPollJitter
      throw new Error 'lookupdPollJitter needs to be a number'
    unless 0 <= params.lookupdPollJitter <= 1
      throw new Error 'lookupdPollJitter needs to be between 0 and 1'

    # Returns a compacted list given a list, string, integer, or object.
    makeList = (list) ->
      list = [list] unless _.isArray list
      (entry for entry in list when entry?)

    params.nsqdTCPAddresses = makeList params.nsqdTCPAddresses
    params.lookupdHTTPAddresses = makeList params.lookupdHTTPAddresses

    anyNotEmpty = (lst...) -> _.some (e for e in lst when not _.isEmpty e)
    unless anyNotEmpty(params.nsqdTCPAddresses, params.lookupdHTTPAddresses)
      throw new Error 'Need to specify either nsqdTCPAddresses or ' +
        'lookupdHTTPAddresses option.'

    params.name = params.name or "#{topic}:#{channel}"
    params.requeueDelay = params.requeueDelay
    params.heartbeatInterval = params.heartbeatInterval

    _.extend @, params

    @roundrobinLookupd = new RoundRobinList @lookupdHTTPAddresses
    @readerRdy = new ReaderRdy @maxInFlight, @maxBackoffDuration
    @connectIntervalId = null
    @connectionIds = []

  connect: ->
    interval = @lookupdPollInterval * 1000
    delay = Math.random() * @lookupdPollJitter * interval

    # Connect to provided nsqds.
    if @nsqdTCPAddresses.length
      directConnect = =>
        # Don't establish new connections while the Reader is paused.
        return if @isPaused()

        if @connectionIds.length < @nsqdTCPAddresses.length
          for addr in @nsqdTCPAddresses
            [address, port] = addr.split ':'
            @connectToNSQD address, Number(port)

      delayedStart = =>
        @connectIntervalId = setInterval directConnect.bind(this), interval

      # Connect immediately.
      directConnect()
      # Start interval for connecting after delay.
      setTimeout delayedStart, delay

    # Connect to nsqds discovered via lookupd
    else
      delayedStart = =>
        @connectIntervalId = setInterval @queryLookupd.bind(this), interval

      # Connect immediately.
      @queryLookupd()
      # Start interval for querying lookupd after delay.
      setTimeout delayedStart, delay

  # Caution: in-flight messages will not get a chance to finish.
  close: ->
    clearInterval @connectIntervalId
    @readerRdy.close()

  pause: ->
    @readerRdy.pause()

  unpause: ->
    @readerRdy.unpause()

  isPaused: ->
    @readerRdy.paused

  queryLookupd: ->
    # Don't establish new connections while the Reader is paused.
    return if @isPaused()

    # Trigger a query of the configured ``lookupdHTTPAddresses``
    endpoint = @roundrobinLookupd.next()
    lookup endpoint, @topic, (err, nodes) =>
      @connectToNSQD n.broadcast_address, n.tcp_port for n in nodes unless err

  connectToNSQD: (host, port) ->
    connectionId = "#{host}:#{port}"
    return if @connectionIds.indexOf(connectionId) isnt -1
    @connectionIds.push connectionId

    conn = new NSQDConnection host, port, @topic, @channel, @requeueDelay,
      @heartbeatInterval

    conn.on NSQDConnection.CONNECTED, =>
      @emit Reader.NSQD_CONNECTED, host, port

    conn.on NSQDConnection.ERROR, (err) =>
      @emit Reader.ERROR, err

    # On close, remove the connection id from this reader.
    conn.on NSQDConnection.CLOSED, =>
      # TODO(dudley): Update when switched to lo-dash
      index = @connectionIds.indexOf connectionId
      return if index is -1
      @connectionIds.splice index, 1

      @emit Reader.NSQD_CLOSED, host, port

    # On message, send either a message or discard event depending on the
    # number of attempts.
    conn.on NSQDConnection.MESSAGE, (message) =>
      # Give the internal event listeners a chance at the events before clients
      # of the Reader.
      process.nextTick =>
        if message.attempts < @maxAttempts
          @emit Reader.MESSAGE, message
        else
          @emit Reader.DISCARD, message

    @readerRdy.addConnection conn

    conn.connect()


module.exports = Reader
