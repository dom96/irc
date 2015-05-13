# (c) Copyright 2012 Dominik Picheta
# Licensed under MIT.       

## This module implements an asynchronous IRC client.
## 
## Currently this module requires at least some knowledge of the IRC protocol.
## It provides a function for sending raw messages to the IRC server, together
## with some basic functions like sending a message to a channel. 
## It automizes the process of keeping the connection alive, so you don't
## need to reply to PING messages. In fact, the server is also PING'ed to check 
## the amount of lag.
##
## .. code-block:: Nimrod
##
##   var client = irc("picheta.me", joinChans = @["#bots"])
##   client.connect()
##   while True:
##     var event: TIRCEvent
##     if client.poll(event):
##       case event.typ
##       of EvConnected: nil
##       of EvDisconnected:
##         client.reconnect()
##       of EvMsg:
##         # Write your message reading code here.
## 
## **Warning:** The API of this module is unstable, and therefore is subject
## to change.

include "system/inclrtl"

import net, strutils, parseutils, times, asyncdispatch, asyncnet, os, tables
from rawsockets import Port
export `[]`

type
  TIrcBase*[SockType] = object
    address: string
    port: Port
    nick, user, realname, serverPass: string
    sock: SockType
    when SockType is AsyncSocket:
      handleEvent: proc (irc: PAsyncIRC, ev: TIRCEvent): Future[void]
    status: TInfo
    lastPing: float
    lastPong: float
    lag: float
    channelsToJoin: seq[string]
    msgLimit: bool
    messageBuffer: seq[tuple[timeToSend: float, m: string]]
    lastReconnect: float
    userList: Table[string, UserList]
  PIrcBase*[T] = ref TIrcBase[T]

  UserList* = ref object
    list: seq[string]
    finished: bool

  PIrc* = ref TIrcBase[Socket]

  PAsyncIrc* = ref TIrcBase[AsyncSocket]

  TIrcMType* = enum
    MUnknown,
    MNumeric,
    MPrivMsg,
    MJoin,
    MPart,
    MMode,
    MTopic,
    MInvite,
    MKick,
    MQuit,
    MNick,
    MNotice,
    MPing,
    MPong,
    MError
  
  TIrcEventType* = enum
    EvMsg, EvConnected, EvDisconnected, EvTimeout
  TIrcEvent* = object ## IRC Event
    case typ*: TIRCEventType
    of EvConnected:
      ## Connected to server. This event is fired when the ``001`` numeric
      ## is received from the server. After this event is fired you can
      ## safely start sending commands to the server.
      nil
    of EvDisconnected:
      ## Disconnected from the server
      nil
    of EvTimeout:
      ## Connection timed out.
      nil
    of EvMsg:              ## Message from the server
      cmd*: TIRCMType      ## Command (e.g. PRIVMSG)
      nick*, user*, host*, servername*: string
      numeric*: string     ## The "numeric" or "verb" of the message
      params*: seq[string] ## Parameters of the IRC message
      origin*: string      ## The channel/user that this msg originated from
      raw*: string         ## Raw IRC message
      timestamp*: Time     ## UNIX epoch time the message was received

  TInfo = enum
    SockConnected, SockConnecting, SockIdle, SockClosed

proc wasBuffered[T](irc: PIrcBase[T], message: string,
                    sendImmediately: bool): bool =
  result = true
  if irc.msgLimit and not sendImmediately:
    var timeToSend = epochTime()
    if irc.messageBuffer.len() >= 3:
      timeToSend = (irc.messageBuffer[irc.messageBuffer.len()-1][0] + 2.0)

    irc.messageBuffer.add((timeToSend, message))
    result = false

proc send*(irc: PIRC, message: string, sendImmediately = false) =
  ## Sends ``message`` as a raw command. It adds ``\c\L`` for you.
  ##
  ## Buffering is performed automatically if you attempt to send messages too
  ## quickly to prevent excessive flooding of the IRC server. You can prevent
  ## buffering by specifying ``True`` for the ``sendImmediately`` param.
  if wasBuffered(irc, message, sendImmediately):
    # The new SafeDisconn flag ensures that this will not raise an exception
    # if the client disconnected.
    irc.sock.send(message & "\c\L")

proc send*(irc: PAsyncIrc, message: string,
           sendImmediately = false): Future[void] =
  ## Sends ``message`` as a raw command asynchronously. It adds ``\c\L`` for 
  ## you.
  ##
  ## Buffering is performed automatically if you attempt to send messages too
  ## quickly to prevent excessive flooding of the IRC server. You can prevent
  ## buffering by specifying ``True`` for the ``sendImmediately`` param.
  if wasBuffered(irc, message, sendImmediately):
    result = irc.sock.send(message & "\c\L")
  else:
    result = newFuture[void]("irc.send")
    result.complete()

proc privmsg*(irc: PIRC, target, message: string) =
  ## Sends ``message`` to ``target``. ``Target`` can be a channel, or a user.
  irc.send("PRIVMSG $1 :$2" % [target, message])

proc privmsg*(irc: PAsyncIrc, target, message: string): Future[void] =
  ## Sends ``message`` to ``target`` asynchronously. ``Target`` can be a 
  ## channel, or a user.
  result = irc.send("PRIVMSG $1 :$2" % [target, message])

proc notice*(irc: PIRC, target, message: string) =
  ## Sends ``notice`` to ``target``. ``Target`` can be a channel, or a user. 
  irc.send("NOTICE $1 :$2" % [target, message])

proc notice*(irc: PAsyncIrc, target, message: string): Future[void] =
  ## Sends ``notice`` to ``target`` asynchronously. ``Target`` can be a
  ## channel, or a user. 
  result = irc.send("NOTICE $1 :$2" % [target, message])

proc join*(irc: PIRC, channel: string, key = "") =
  ## Joins ``channel``.
  ## 
  ## If key is not ``""``, then channel is assumed to be key protected and this
  ## function will join the channel using ``key``.
  if key == "":
    irc.send("JOIN " & channel)
  else:
    irc.send("JOIN " & channel & " " & key)

proc join*(irc: PAsyncIrc, channel: string, key = ""): Future[void] =
  ## Joins ``channel`` asynchronously.
  ## 
  ## If key is not ``""``, then channel is assumed to be key protected and this
  ## function will join the channel using ``key``.
  if key == "":
    result = irc.send("JOIN " & channel)
  else:
    result = irc.send("JOIN " & channel & " " & key)

proc part*(irc: PIRC, channel, message: string) =
  ## Leaves ``channel`` with ``message``.
  irc.send("PART " & channel & " :" & message)

proc part*(irc: PAsyncIrc, channel, message: string): Future[void] =
  ## Leaves ``channel`` with ``message`` asynchronously.
  result = irc.send("PART " & channel & " :" & message)

proc close*(irc: PIrc | PAsyncIrc) =
  ## Closes connection to an IRC server.
  ##
  ## **Warning:** This procedure does not send a ``QUIT`` message to the server.
  irc.status = SockClosed
  irc.sock.close()

proc isNumber(s: string): bool =
  ## Checks if `s` contains only numbers.
  var i = 0
  while s[i] in {'0'..'9'}: inc(i)
  result = i == s.len and s.len > 0

proc parseMessage(msg: string): TIRCEvent =
  result.typ       = EvMsg
  result.cmd       = MUnknown
  result.raw       = msg
  result.timestamp = times.getTime()
  var i = 0
  # Process the prefix
  if msg[i] == ':':
    inc(i) # Skip `:`
    var nick = ""
    i.inc msg.parseUntil(nick, {'!', ' '}, i)
    result.nick = ""
    result.serverName = ""
    if msg[i] == '!':
      result.nick = nick
      inc(i) # Skip `!`
      i.inc msg.parseUntil(result.user, {'@'}, i)
      inc(i) # Skip `@`
      i.inc msg.parseUntil(result.host, {' '}, i)
      inc(i) # Skip ` `
    else:
      result.serverName = nick
      inc(i) # Skip ` `
  
  # Process command
  var cmd = ""
  i.inc msg.parseUntil(cmd, {' '}, i)

  if cmd.isNumber:
    result.cmd = MNumeric
    result.numeric = cmd
  else:
    result.numeric = cmd # Save the verb for downstream
    case cmd
    of "PRIVMSG": result.cmd = MPrivMsg
    of "JOIN": result.cmd = MJoin
    of "PART": result.cmd = MPart
    of "PONG": result.cmd = MPong
    of "PING": result.cmd = MPing
    of "MODE": result.cmd = MMode
    of "TOPIC": result.cmd = MTopic
    of "INVITE": result.cmd = MInvite
    of "KICK": result.cmd = MKick
    of "QUIT": result.cmd = MQuit
    of "NICK": result.cmd = MNick
    of "NOTICE": result.cmd = MNotice
    of "ERROR": result.cmd = MError
    else: result.cmd = MUnknown
  
  # Don't skip space here. It is skipped in the following While loop.
  
  # Params
  result.params = @[]
  var param = ""
  while msg[i] != '\0' and msg[i] != ':':
    inc(i) # Skip ` `.
    i.inc msg.parseUntil(param, {' ', ':', '\0'}, i)
    if param != "":
      result.params.add(param)
      param.setlen(0)
  
  if msg[i] == ':':
    inc(i) # Skip `:`.
    result.params.add(msg[i..msg.len-1])

proc connect*(irc: PIRC) =
  ## Connects to an IRC server as specified by ``irc``.
  assert(irc.address != "")
  assert(irc.port != Port(0))
  
  irc.sock.connect(irc.address, irc.port)
 
  irc.status = SockConnected
  
  # Greet the server :)
  if irc.serverPass != "": irc.send("PASS " & irc.serverPass, true)
  irc.send("NICK " & irc.nick, true)
  irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)

proc reconnect*(irc: PIRC, timeout = 5000) =
  ## Reconnects to an IRC server.
  ##
  ## ``Timeout`` specifies the time to wait in miliseconds between multiple
  ## consecutive reconnections.
  ##
  ## This should be used when an ``EvDisconnected`` event occurs.
  let secSinceReconnect = epochTime() - irc.lastReconnect
  if secSinceReconnect < (timeout/1000):
    sleep(timeout - (secSinceReconnect*1000).int)
  irc.sock = newSocket()
  irc.connect()
  irc.lastReconnect = epochTime()

proc newIrc*(address: string, port: Port = 6667.Port,
         nick = "NimrodBot",
         user = "NimrodBot",
         realname = "NimrodBot", serverPass = "",
         joinChans: seq[string] = @[],
         msgLimit: bool = true): PIRC =
  ## Creates a ``TIRC`` object.
  new(result)
  result.address = address
  result.port = port
  result.nick = nick
  result.user = user
  result.realname = realname
  result.serverPass = serverPass
  result.lastPing = epochTime()
  result.lastPong = -1.0
  result.lag = -1.0
  result.channelsToJoin = joinChans
  result.msgLimit = msgLimit
  result.messageBuffer = @[]
  result.status = SockIdle
  result.sock = newSocket()
  result.userList = initTable[string, UserList]()

proc remNick(irc: PIrc | PAsyncIrc, chan, nick: string) =
  ## Removes ``nick`` from ``chan``'s user list.
  var newList: seq[string] = @[]
  for n in irc.userList[chan].list:
    if n != nick:
      newList.add n
  irc.userList[chan].list = newList

proc addNick(irc: PIrc | PAsyncIrc, chan, nick: string) =
  ## Adds ``nick`` to ``chan``'s user list.
  var stripped = nick
  # Strip common nick prefixes
  if nick[0] in {'+', '@', '%', '!', '&', '~'}: stripped = nick[1 .. <nick.len]

  irc.userList[chan].list.add(stripped)

proc processLine(irc: PIrc | PAsyncIrc, line: string): TIRCEvent =
  if line.len == 0:
    irc.close()
    result.typ = EvDisconnected
  else:
    result = parseMessage(line)
    # Get the origin
    result.origin = result.params[0]
    if result.origin == irc.nick and
       result.nick != "": result.origin = result.nick

    if result.cmd == MError:
      irc.close()
      result.typ = EvDisconnected
      return

    if result.cmd == MPong:
      irc.lag = epochTime() - parseFloat(result.params[result.params.high])
      irc.lastPong = epochTime()

    if result.cmd == MNumeric:
      case result.numeric
      of "001":
        # Check the nickname.
        if irc.nick != result.params[0]:
          assert ' ' notin result.params[0]
          irc.nick = result.params[0]
      of "353":
        let chan = result.params[2]
        if not irc.userList.hasKey(chan):
          irc.userList[chan] = UserList(finished: false, list: @[])
        if irc.userList[chan].finished:
          irc.userList[chan].finished = false
          irc.userList[chan].list = @[]
        for i in result.params[3].split(' '):
          addNick(irc, chan, i)
      of "366":
        let chan = result.params[1]
        assert irc.userList.hasKey(chan)
        irc.userList[chan].finished = true

    if result.cmd == MNick:
      if result.nick == irc.nick:
        irc.nick = result.params[0]

      # Update user list.
      for chan in keys(irc.userList):
        irc.remNick(chan, result.nick)
        irc.addNick(chan, result.params[0])

    if result.cmd == MJoin:
      if irc.userList.hasKey(result.origin):
        addNick(irc, result.origin, result.nick)

    if result.cmd == MPart:
      remNick(irc, result.origin, result.nick)
      if result.nick == irc.nick:
        irc.userList.del(result.origin)

    if result.cmd == MKick:
      remNick(irc, result.origin, result.params[1])

    if result.cmd == MQuit:
      # Update user list.
      for chan in keys(irc.userList):
        irc.remNick(chan, result.nick)

proc replyToLine(irc: PIrc, ev: TIrcEvent) =
  if ev.typ == EvMsg:
    if ev.cmd == MPing:
      irc.send("PONG " & ev.params[0])
    
    if ev.cmd == MNumeric:
      if ev.numeric == "001":
        # Join channels.
        for chan in items(irc.channelsToJoin):
          irc.join(chan)

proc replyToLine(irc: PAsyncIrc, ev: TIrcEvent) {.async.} =
  if ev.typ == EvMsg:
    if ev.cmd == MPing:
      await irc.send("PONG " & ev.params[0])
    
    if ev.cmd == MNumeric:
      if ev.numeric == "001":
        # Join channels.
        for chan in items(irc.channelsToJoin):
          await irc.join(chan)

proc processOther(irc: PIRC, ev: var TIRCEvent): bool =
  result = false
  if epochTime() - irc.lastPing >= 20.0:
    irc.lastPing = epochTime()
    irc.send("PING :" & formatFloat(irc.lastPing), true)

  if epochTime() - irc.lastPong >= 120.0 and irc.lastPong != -1.0:
    irc.close()
    ev.typ = EvTimeout
    return true
  
  for i in 0..irc.messageBuffer.len-1:
    if epochTime() >= irc.messageBuffer[0][0]:
      irc.send(irc.messageBuffer[0].m, true)
      irc.messageBuffer.delete(0)
    else:
      break # messageBuffer is guaranteed to be from the quickest to the
            # later-est.

proc processOtherForever(irc: PAsyncIRC) {.async.} =
  while true:
    # TODO: Consider improving this.
    await sleepAsync(1000)
    if epochTime() - irc.lastPing >= 20.0:
      irc.lastPing = epochTime()
      await irc.send("PING :" & formatFloat(irc.lastPing), true)

    if epochTime() - irc.lastPong >= 120.0 and irc.lastPong != -1.0:
      irc.close()
      var ev: TIrcEvent
      ev.typ = EvTimeout
      asyncCheck irc.handleEvent(irc, ev)
    
    for i in 0..irc.messageBuffer.len-1:
      if epochTime() >= irc.messageBuffer[0][0]:
        await irc.send(irc.messageBuffer[0].m, true)
        irc.messageBuffer.delete(0)
      else:
        break # messageBuffer is guaranteed to be from the quickest to the
              # later-est.

proc poll*(irc: PIRC, ev: var TIRCEvent,
           timeout: int = 500): bool =
  ## This function parses a single message from the IRC server and returns 
  ## a TIRCEvent.
  ##
  ## This function should be called often as it also handles pinging
  ## the server.
  ##
  ## This function provides a somewhat asynchronous IRC implementation, although
  ## it should only be used for simple things for example an IRC bot which does
  ## not need to be running many time critical tasks in the background. If you
  ## require this, use the asyncio implementation.
  result = true
  if not (irc.status == SockConnected):
    # Do not close the socket here, it is already closed!
    ev.typ = EvDisconnected
  var line = TaintedString""
  try:
    irc.sock.readLine(line, timeout)
  except TimeoutError:
    result = false
  if result:
    ev = irc.processLine(line.string)
    replyToLine(irc, ev)

  if processOther(irc, ev): result = true

proc getLag*(irc: PIrc | PAsyncIrc): float =
  ## Returns the latency between this client and the IRC server in seconds.
  ## 
  ## If latency is unknown, returns -1.0.
  return irc.lag

proc isConnected*(irc: PIrc | PAsyncIrc): bool =
  ## Returns whether this IRC client is connected to an IRC server.
  return irc.status == SockConnected

proc getNick*(irc: PIrc | PAsyncIrc): string =
  ## Returns the current nickname of the client.
  return irc.nick

proc getUserList*(irc: PIrc | PAsyncIrc, channel: string): seq[string] =
  ## Returns the specified channel's user list. The specified channel should
  ## be in the form of ``#chan``.
  return irc.userList[channel].list

# -- Asyncio dispatcher

proc connect*(irc: PAsyncIRC) {.async.} =
  ## Connects to the IRC server as specified by the ``AsyncIrc`` instance passed
  ## to this procedure.
  assert(irc.address != "")
  assert(irc.port != Port(0))
  irc.status = SockConnecting
  
  await irc.sock.connect(irc.address, irc.port)

  if irc.serverPass != "": await irc.send("PASS " & irc.serverPass, true)
  await irc.send("NICK " & irc.nick, true)
  await irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)
  irc.status = SockConnected

proc reconnect*(irc: PAsyncIRC, timeout = 5000) {.async.} =
  ## Reconnects to an IRC server.
  ##
  ## ``Timeout`` specifies the time to wait in miliseconds between multiple
  ## consecutive reconnections.
  ##
  ## This should be used when an ``EvDisconnected`` event occurs.
  let secSinceReconnect = epochTime() - irc.lastReconnect
  if secSinceReconnect < (timeout/1000):
    await sleepAsync(timeout - int(secSinceReconnect * 1000))
  irc.sock.close()
  irc.sock = newAsyncSocket()
  await irc.connect()
  irc.lastReconnect = epochTime()

proc newAsyncIrc*(address: string, port: Port = 6667.Port,
              nick = "NimrodBot",
              user = "NimrodBot",
              realname = "NimrodBot", serverPass = "",
              joinChans: seq[string] = @[],
              msgLimit: bool = true,
              callback: proc (irc: PAsyncIRC, ev: TIRCEvent): Future[void]
              ): PAsyncIrc =
  ## Creates a new asynchronous IRC object instance.
  ## 
  ## **Note:** Do **NOT** use this if you're writing a simple IRC bot which only
  ## requires one task to be run, i.e. this should not be used if you want a
  ## synchronous IRC client implementation, use ``irc`` for that.
  
  new(result)
  result.address = address
  result.port = port
  result.nick = nick
  result.user = user
  result.realname = realname
  result.serverPass = serverPass
  result.lastPing = epochTime()
  result.lastPong = -1.0
  result.lag = -1.0
  result.channelsToJoin = joinChans
  result.msgLimit = msgLimit
  result.messageBuffer = @[]
  result.handleEvent = callback
  result.sock = newAsyncSocket()
  result.status = SockIdle
  result.userList = initTable[string, UserList]()

proc run*(irc: PAsyncIrc) {.async.} =
  ## Initiates the long-running event loop.
  ##
  ## This asynchronous procedure
  ## will keep receiving messages from the IRC server and will fire appropriate
  ## events until the IRC client is closed by the user, the server closes
  ## the connection, or an error occurs.
  ##
  ## You should not ``await`` this procedure but you should ``asyncCheck`` it.
  ##
  ## For convenience, this procedure will call ``connect`` implicitly if it was
  ## not previously called.
  if irc.status notin {SockConnected, SockConnecting}:
    await irc.connect()

  asyncCheck irc.processOtherForever()
  while true:
    var line = await irc.sock.recvLine()
    var ev = irc.processLine(line.string)
    await irc.replyToLine(ev)
    asyncCheck irc.handleEvent(irc, ev)

