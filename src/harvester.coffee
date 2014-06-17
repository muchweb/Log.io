fs = require 'fs'
net = require 'net'
events = require 'events'
winston = require 'winston'

###*
# Mainly used by `LogHarvester`.
# 
#  - Watches log file for changes
#  - Extracts new log messages
#  - Then emits 'new_log' events.
# 
# @class LogStream
# @extends events.EventEmitter
###
class LogStream extends events.EventEmitter

  ###*
  # Initializing new `LogStream` instance
  # @constructor
  # @param {Object} name name of current log stream. Only used for debugging.
  # @param {Object} paths Array of local files paths. 
  # @param {Object} _log Winston (or compatible) logger object. Only used for debugging.
  ###
  constructor: (@name, @paths, @_log) ->

  ###*
  # Initialising all file watching
  # @method watch
  ###
  watch: ->
    @_log.info "Starting log stream: '#{@name}'"
    @_watchFile path for path in @paths
    @

  ###*
  # Watching all files under specified directory
  # @method watch
  # @param {String} path Path to directory
  ###
  _watchDirectory: (path) ->
    filesUnderFolder = fs.readdirSync(path)
    for i of filesUnderFolder
      @_watchFile path + "/" + filesUnderFolder[i]

  ###*
  # Starting to watch file changes.
  # @method watch
  # @param {String} path Path to file or a directory
  ###
  _watchFile: (path) ->
      # Checking if file exists
      if not fs.existsSync path
        @_log.error "File doesn't exist: '#{path}'. Retrying in 1000ms."
        setTimeout (=> @_watchFile path), 1000
        return

      # Checking if path is a directory
      if fs.lstatSync(path).isDirectory()
        @_watchDirectory(path);
        return

      @_log.info "Watching file: '#{path}'"
      currSize = fs.statSync(path).size
      watcher = fs.watch path, (event, filename) =>
        if event is 'rename'
          # File has been rotated, start new watcher
          watcher.close()
          @_watchFile path

        if event is 'change'
          # Capture file offset information for change event
          fs.stat path, (err, stat) =>
            @_readNewLogs path, stat.size, currSize
            currSize = stat.size

  ###*
  # File change has been detected. Determining what has been changed and emitting `new_log` event.
  # @method watch
  # @param {String} path Path to file or a directory
  ###
  _readNewLogs: (path, curr, prev) ->
    # Use file offset information to stream new log lines from file
    return if curr < prev
    rstream = fs.createReadStream path,
      encoding: 'utf8'
      start: prev
      end: curr

    # Emit `new_log` event for every captured log line
    rstream.on 'data', (data) =>
      lines = data.split "\n"
      @emit 'new_log', line for line in lines when line

###*
# `LogHarvester` creates `LogStream` for each file watched and opens a persistent TCP connection to the server.
# 
# Watches local files and sends new log message to server via TCP.
# 
# On startup it announces itself as Node with Stream associations.
# 
# Log messages are sent to the server via string-delimited TCP messages.
# 
# Sample configuration:
# 
#     config =
#       nodeName: 'my_server01'
#       logStreams:
#         web_server: [
#           '/var/log/nginx/access.log',
#           '/var/log/nginx/error.log'
#         ],
#         customLogs: [
#           "/var/log/myCustomLogs/"
#         ],
#       server:
#         host: '0.0.0.0',
#         port: 28777
# 
# Configuration above sends the following TCP messages to the server:
# 
#     "+node|my_server01|web_server\r\n"
#     "+bind|node|my_server01\r\n"
#     "+log|web_server|my_server01|info|this is log messages\r\n"
# 
# Usage:
# 
#     harvester = new LogHarvester config
#     harvester.run()
#
# @class LogHarvester
###
class LogHarvester

  ###*
  # Maximum server connection retry time, in milliseconds
  # @property TIMEOUT_RECONNECT_MAX
  # @type Number
  # @default 60000
  ###
  TIMEOUT_RECONNECT_MAX: 60000;

  ###*
  # Starting server connection retry time, in milliseconds
  # @property TIMEOUT_RECONNECT_START
  # @type Number
  # @default 1000
  ###
  TIMEOUT_RECONNECT_START: 1000;

  ###*
  # Initializing new `LogHarvester` instance
  #
  # Default configuration:
  #
  #     config =
  #       nodeName: 'Untitled'
  #       delimiter: '\r\n'
  #       _log: winston
  #       logStreams: {}
  #       server:
  #         host: '0.0.0.0',
  #         port: 28777
  #
  # @constructor
  # @param {Object} config harvester configuration
  ###
  constructor: (config = {}) ->
    config.nodeName = config.nodeName ? 'Untitled'
    config.delimiter = config.delimiter ? '\r\n'
    config._log = config._log ? winston
    config.logStreams = config.logStreams ? {}
    config.server = config.server ?
      host: '0.0.0.0',
      port: 28777

    {@nodeName, @server, @delimiter, @_log} = config
    @logStreams = (new LogStream s, paths, @_log for s, paths of config.logStreams)
    @timeout_reconnect = @TIMEOUT_RECONNECT_START;

  ###*
  # Run harvester and connect to server
  # @method run
  ###
  run: ->
    @_connect()
    @logStreams.forEach (stream) =>
      stream.watch().on 'new_log', (msg) =>
        @_sendLog stream, msg if @_connected

  ###*
  # Creating TCP socket
  # @method _connect
  ###
  _connect: ->
    @socket = new net.Socket
    
    @socket.on 'error', (error) =>
      @_connected = false
      @_log.error "Cannot connect to server, trying again in #{(@timeout_reconnect/1000)} second(s)..."
      setTimeout (=> @_connect()), @timeout_reconnect
      @timeout_reconnect = Math.min @timeout_reconnect * 2, @TIMEOUT_RECONNECT_MAX;

    @_log.info "Connecting to server #{@server.host}:#{@server.port}..."
    @socket.connect @server.port, @server.host, =>
      @_connected = true
      @timeout_reconnect = @TIMEOUT_RECONNECT_START;
      @_announce()

  ###*
  # Creating TCP socket
  # @method _sendLog
  # @param {Object} stream Stream that message is received from
  # @param {String} msg Log message body
  ###
  _sendLog: (stream, msg) ->
    @_log.debug "Sending log: (#{stream.name}) #{msg}"
    @_send '+log', stream.name, @nodeName, 'info', msg 

  ###*
  # Registed harvester to server
  # @method _announce
  ###
  _announce: ->
    snames = (l.name for l in @logStreams).join ","
    @_log.info "Announcing: #{@nodeName} (#{snames})"
    @_send '+node', @nodeName, snames
    @_send '+bind', 'node', @nodeName

  ###*
  # Writing message directly to socket
  # @method _send
  # @param {String} mtype Message type
  # @param {Object} args Array of message strings
  ###
  _send: (mtype, args...) ->
    @socket.write "#{mtype}|#{args.join '|'}#{@delimiter}"

exports.LogHarvester = LogHarvester