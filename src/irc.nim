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
## .. code-block:: Nim
##
##   let client = newIrc("picheta.me", joinChans = @["#bots"])
##   client.connect()
##   while True:
##     var event: IrcEvent
##     if client.poll(event):
##       case event.typ
##       of EvConnected: discard
##       of EvDisconnected:
##         client.reconnect()
##       of EvMsg:
##         # Write your message reading code here.
##         echo event.raw
##      else: discard
##
## **Warning:** The API of this module is unstable, and therefore is subject
## to change.

include "system/inclrtl"

import net, strutils, strtabs, parseutils, times, asyncdispatch, asyncnet
import os, tables, deques
import std/base64

from nativesockets import Port
export `[]`

type
  IrcBaseObj*[SockType] = object
    address: string
    port: Port
    nick, user, realname, serverPass, nickservPass: string
    sock: SockType
    when SockType is AsyncSocket:
      handleEvent: proc (irc: AsyncIrc, ev: IrcEvent): Future[void]
    else:
      eventsQueue: Deque[IrcEvent]
    status: Info
    lastPing: float
    lastPong: float
    lag: float
    channelsToJoin: seq[string]
    msgLimit: bool
    messageBuffer: seq[tuple[timeToSend: float, m: string]]
    lastReconnect: float
    userList: Table[string, UserList]
  IrcBase*[T] = ref IrcBaseObj[T]

  UserList* = ref object
    list: seq[string]
    finished: bool

  Irc* = ref IrcBaseObj[Socket]

  AsyncIrc* = ref IrcBaseObj[AsyncSocket]

  IrcMType* = enum
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

  IrcEventType* = enum
    EvMsg, EvConnected, EvDisconnected, EvTimeout
  IrcEvent* = object ## IRC Event
    case typ*: IrcEventType
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
    of EvMsg:               ## Message from the server
      cmd*: IrcMType        ## Command (e.g. PRIVMSG)
      nick*, user*, host*, servername*: string
      numeric*: string      ## Only applies to ``MNumeric``
      tags*: StringTableRef ## IRCv3 tags at the start of the message
      params*: seq[string]  ## Parameters of the IRC message
      origin*: string       ## The channel/user that this msg originated from
      raw*: string          ## Raw IRC message
      text*: string         ## Text intended for the recipient (the last value in params).
      timestamp*: Time      ## UNIX epoch time the message was received

  Info = enum
    SockConnected, SockConnecting, SockIdle, SockClosed

{.deprecated: [TIrcBase: IrcBaseObj, TIrcMType: IrcMType,
               TIrcEventType: IrcEventType, TIrcEvent: IrcEvent].}

when not defined(ssl):
  type SSLContext = ref object
var defaultSslContext {.threadvar.}: SSLContext

proc getDefaultSSL(): SSLContext =
  result = defaultSslContext
  when defined(ssl):
    if result == nil:
      defaultSslContext = newContext(verifyMode = CVerifyNone)
      result = defaultSslContext
      doAssert result != nil, "failure to initialize the SSL context"

proc wasBuffered[T](irc: IrcBase[T], message: string,
                    sendImmediately: bool): bool =
  result = true
  if irc.msgLimit and not sendImmediately:
    var timeToSend = epochTime()
    if irc.messageBuffer.len() >= 3:
      timeToSend = (irc.messageBuffer[irc.messageBuffer.len()-1][0] + 2.0)

    irc.messageBuffer.add((timeToSend, message))
    result = false

proc send*(irc: Irc, message: string, sendImmediately = false) =
  ## Sends ``message`` as a raw command. It adds ``\c\L`` for you.
  ##
  ## Buffering is performed automatically if you attempt to send messages too
  ## quickly to prevent excessive flooding of the IRC server. You can prevent
  ## buffering by specifying ``True`` for the ``sendImmediately`` param.
  if wasBuffered(irc, message, sendImmediately):
    # The new SafeDisconn flag ensures that this will not raise an exception
    # if the client disconnected.
    irc.sock.send(message & "\c\L")

proc send*(irc: AsyncIrc, message: string,
           sendImmediately = false): Future[void] =
  ## Sends ``message`` as a raw command asynchronously. It adds ``\c\L`` for
  ## you.
  ##
  ## Buffering is performed automatically if you attempt to send messages too
  ## quickly to prevent excessive flooding of the IRC server. You can prevent
  ## buffering by specifying ``True`` for the ``sendImmediately`` param.
  if wasBuffered(irc, message, sendImmediately):
    assert irc.status notin [SockClosed, SockConnecting]
    return irc.sock.send(message & "\c\L")
  result = newFuture[void]("irc.send")
  result.complete()

proc privmsg*(irc: Irc, target, message: string) =
  ## Sends ``message`` to ``target``. ``Target`` can be a channel, or a user.
  irc.send("PRIVMSG $1 :$2" % [target, message])

proc privmsg*(irc: AsyncIrc, target, message: string): Future[void] =
  ## Sends ``message`` to ``target`` asynchronously. ``Target`` can be a
  ## channel, or a user.
  result = irc.send("PRIVMSG $1 :$2" % [target, message])

proc notice*(irc: Irc, target, message: string) =
  ## Sends ``notice`` to ``target``. ``Target`` can be a channel, or a user.
  irc.send("NOTICE $1 :$2" % [target, message])

proc notice*(irc: AsyncIrc, target, message: string): Future[void] =
  ## Sends ``notice`` to ``target`` asynchronously. ``Target`` can be a
  ## channel, or a user.
  result = irc.send("NOTICE $1 :$2" % [target, message])

proc join*(irc: Irc, channel: string, key = "") =
  ## Joins ``channel``.
  ##
  ## If key is not ``""``, then channel is assumed to be key protected and this
  ## function will join the channel using ``key``.
  if key == "":
    irc.send("JOIN " & channel)
  else:
    irc.send("JOIN " & channel & " " & key)

proc join*(irc: AsyncIrc, channel: string, key = ""): Future[void] =
  ## Joins ``channel`` asynchronously.
  ##
  ## If key is not ``""``, then channel is assumed to be key protected and this
  ## function will join the channel using ``key``.
  if key == "":
    result = irc.send("JOIN " & channel)
  else:
    result = irc.send("JOIN " & channel & " " & key)

proc part*(irc: Irc, channel, message: string) =
  ## Leaves ``channel`` with ``message``.
  irc.send("PART " & channel & " :" & message)

proc part*(irc: AsyncIrc, channel, message: string): Future[void] =
  ## Leaves ``channel`` with ``message`` asynchronously.
  result = irc.send("PART " & channel & " :" & message)

proc close*(irc: Irc | AsyncIrc) =
  ## Closes connection to an IRC server.
  ##
  ## **Warning:** This procedure does not send a ``QUIT`` message to the server.
  irc.status = SockClosed
  irc.sock.close()

proc isNumber(s: string): bool =
  ## Checks if `s` contains only numbers.
  var i = 0
  while i < s.len and s[i] in {'0'..'9'}: inc(i)
  result = i == s.len and s.len > 0

proc parseMessage(msg: string): IrcEvent =
  result = IrcEvent(typ: EvMsg)
  result.cmd       = MUnknown
  result.tags      = newStringTable()
  result.raw       = msg
  result.timestamp = times.getTime()
  var i = 0
  # Process the tags
  if msg[i] == '@':
    inc(i)
    var tags = ""
    i.inc msg.parseUntil(tags, {' '}, i)
    for tag in tags.split(';'):
      var pair = tag.split('=')
      result.tags[pair[0]] = pair[1]
    inc(i)
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
  while i < msg.len and msg[i] != ':':
    inc(i) # Skip ` `.
    i.inc msg.parseUntil(param, {' ', ':', '\0'}, i)
    if param != "":
      result.params.add(param)
      param.setlen(0)

  if i < msg.len and msg[i] == ':':
    inc(i) # Skip `:`.
    result.params.add(msg[i..msg.len-1])

  if result.params.len > 0:
    result.text = result.params[^1]

proc connect*(irc: Irc) =
  ## Connects to an IRC server as specified by ``irc``.
  assert(irc.address != "")
  assert(irc.port != Port(0))

  irc.status = SockConnecting
  irc.sock.connect(irc.address, irc.port)
  irc.status = SockConnected

  if irc.nickservPass != "": 
    irc.send("CAP LS")
    irc.send("NICK " & irc.nick, true)
    irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)
    irc.send("CAP REQ :multi-prefix sasl")
    irc.send("AUTHENTICATE PLAIN")
    let encodedpass = encode(char(0) &  irc.nick & char(0) & irc.nickservPass)
    irc.send("AUTHENTICATE " & encodedpass)
    irc.send("CAP END")
  else:
    if irc.serverPass != "": irc.send("PASS " & irc.serverPass, true)
    irc.send("NICK " & irc.nick, true)
    irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)

proc reconnect*(irc: Irc, timeout = 5000) =
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
         nick = "NimBot",
         user = "NimBot",
         realname = "NimBot", serverPass = "", nickservPass = "",
         joinChans: seq[string] = @[],
         msgLimit: bool = true,
         useSsl: bool = false,
         sslContext = getDefaultSSL()): Irc =
  ## Creates a ``Irc`` object.
  new(result)
  result.address = address
  result.port = port
  result.nick = nick
  result.user = user
  result.realname = realname
  result.serverPass = serverPass
  result.nickservPass = nickservPass
  result.lastPing = epochTime()
  result.lastPong = -1.0
  result.lag = -1.0
  result.channelsToJoin = joinChans
  result.msgLimit = msgLimit
  result.messageBuffer = @[]
  result.status = SockIdle
  result.sock = newSocket()
  result.userList = initTable[string, UserList]()
  result.eventsQueue = initDeque[IrcEvent]()

  when defined(ssl):
    if useSsl:
      try:
        sslContext.wrapSocket(result.sock)
      except:
        result.sock.close()
        raise

proc remNick(irc: Irc | AsyncIrc, chan, nick: string) =
  ## Removes ``nick`` from ``chan``'s user list.
  var newList: seq[string] = @[]
  if chan in irc.userList:
    for n in irc.userList[chan].list:
      if n != nick:
        newList.add n
  irc.userList[chan].list = newList

proc addNick(irc: Irc | AsyncIrc, chan, nick: string) =
  ## Adds ``nick`` to ``chan``'s user list.
  var stripped = nick
  # Strip common nick prefixes
  if nick[0] in {'+', '@', '%', '!', '&', '~'}: stripped = nick[1 ..< nick.len]

  if chan notin irc.userList:
    irc.userList[chan] = UserList(finished: false, list: @[])
  irc.userList[chan].list.add(stripped)

proc processLine(irc: Irc | AsyncIrc, line: string): IrcEvent =
  if line.len == 0:
    irc.close()
    result = IrcEvent(typ: EvDisconnected)
  else:
    result = parseMessage(line)
    
    # Get the origin
    result.origin = result.params[0]
    if result.origin == irc.nick and
       result.nick != "": result.origin = result.nick

    if result.cmd == MError:
      irc.close()
      result = IrcEvent(typ: EvDisconnected)
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
        for i in result.params[3].splitWhitespace():
          addNick(irc, chan, i)
      of "366":
        let chan = result.params[1]
        assert irc.userList.hasKey(chan)
        irc.userList[chan].finished = true
      else:
        discard

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

proc handleLineEvents(irc: Irc | AsyncIrc, ev: IrcEvent) {.multisync.} =
  if ev.typ == EvMsg:
    if ev.cmd == MPing:
      await irc.send("PONG " & ev.params[0])

    if ev.cmd == MNumeric:
      if ev.numeric == "001":
        # Join channels.
        for chan in items(irc.channelsToJoin):
          await irc.join(chan)

        # Emit connected event.
        var ev = IrcEvent(typ: EvConnected)
        when irc is IRC:
          irc.eventsQueue.addLast(ev)
        else:
          asyncCheck irc.handleEvent(irc, ev)

proc processOther(irc: Irc, ev: var IrcEvent): bool =
  result = false
  if epochTime() - irc.lastPing >= 20.0:
    irc.lastPing = epochTime()
    irc.send("PING :" & formatFloat(irc.lastPing), true)

  if epochTime() - irc.lastPong >= 120.0 and irc.lastPong != -1.0:
    irc.close()
    ev = IrcEvent(typ: EvTimeout)
    return true

  for i in 0..irc.messageBuffer.len-1:
    if epochTime() >= irc.messageBuffer[0][0]:
      irc.send(irc.messageBuffer[0].m, true)
      irc.messageBuffer.delete(0)
    else:
      break # messageBuffer is guaranteed to be from the quickest to the
            # later-est.

proc processOtherForever(irc: AsyncIrc) {.async.} =
  while true:
    # TODO: Consider improving this.
    await sleepAsync(1000)
    if epochTime() - irc.lastPing >= 20.0:
      irc.lastPing = epochTime()
      await irc.send("PING :" & formatFloat(irc.lastPing), true)

    if epochTime() - irc.lastPong >= 120.0 and irc.lastPong != -1.0:
      irc.close()
      var ev = IrcEvent(typ: EvTimeout)
      asyncCheck irc.handleEvent(irc, ev)

    for i in 0..irc.messageBuffer.len-1:
      if epochTime() >= irc.messageBuffer[0][0]:
        await irc.send(irc.messageBuffer[0].m, true)
        irc.messageBuffer.delete(0)
      else:
        break # messageBuffer is guaranteed to be from the quickest to the
              # later-est.

proc poll*(irc: Irc, ev: var IrcEvent,
           timeout: int = 500): bool =
  ## This function parses a single message from the IRC server and returns
  ## a IRCEvent.
  ##
  ## This function should be called often as it also handles pinging
  ## the server.
  ##
  ## This function provides a somewhat asynchronous IRC implementation, although
  ## it should only be used for simple things, for example an IRC bot which does
  ## not need to be running many time critical tasks in the background. If you
  ## require this, use the AsyncIrc implementation.
  result = true
  if irc.eventsQueue.len > 0:
    ev = irc.eventsQueue.popFirst()
    return

  if not (irc.status == SockConnected):
    # Do not close the socket here, it is already closed!
    ev = IrcEvent(typ: EvDisconnected)
  var line = TaintedString""
  try:
    irc.sock.readLine(line, timeout)
  except TimeoutError:
    result = false
  if result:
    ev = irc.processLine(line.string)
    handleLineEvents(irc, ev)

  if processOther(irc, ev): result = true

proc getLag*(irc: Irc | AsyncIrc): float =
  ## Returns the latency between this client and the IRC server in seconds.
  ##
  ## If latency is unknown, returns -1.0.
  return irc.lag

proc isConnected*(irc: Irc | AsyncIrc): bool =
  ## Returns whether this IRC client is connected to an IRC server.
  return irc.status == SockConnected

proc getNick*(irc: Irc | AsyncIrc): string =
  ## Returns the current nickname of the client.
  return irc.nick

proc getUserList*(irc: Irc | AsyncIrc, channel: string): seq[string] =
  ## Returns the specified channel's user list. The specified channel should
  ## be in the form of ``#chan``.
  if channel in irc.userList:
    result = irc.userList[channel].list

# -- Asyncio dispatcher

proc connect*(irc: AsyncIrc) {.async.} =
  ## Connects to the IRC server as specified by the ``AsyncIrc`` instance passed
  ## to this procedure.
  assert(irc.address != "")
  assert(irc.port != Port(0))

  irc.status = SockConnecting
  await irc.sock.connect(irc.address, irc.port)
  irc.status = SockConnected

  if irc.nickservPass != "": 
    await irc.send("CAP LS")
    await irc.send("NICK " & irc.nick, true)
    await irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)
    await irc.send("CAP REQ :multi-prefix sasl")
    await irc.send("AUTHENTICATE PLAIN")
    let encodedpass = encode(char(0) &  irc.nick & char(0) & irc.nickservPass)
    await irc.send("AUTHENTICATE " & encodedpass)
    await irc.send("CAP END")
  else:
    if irc.serverPass != "": await irc.send("PASS " & irc.serverPass, true)
    await irc.send("NICK " & irc.nick, true)
    await irc.send("USER $1 * 0 :$2" % [irc.user, irc.realname], true)

proc reconnect*(irc: AsyncIrc, timeout = 5000) {.async.} =
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
              nick = "NimBot",
              user = "NimBot",
              realname = "NimBot123", serverPass = "", nickservPass = "",
              joinChans: seq[string] = @[],
              msgLimit: bool = true,
              useSsl: bool = false,
              sslContext = getDefaultSSL(),
              callback: proc (irc: AsyncIrc, ev: IrcEvent): Future[void]
              ): AsyncIrc =
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
  result.nickservPass = nickservPass
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

  when defined(ssl):
    if useSsl:
      try:
        sslContext.wrapSocket(result.sock)
      except:
        result.sock.close()
        raise

proc run*(irc: AsyncIrc) {.async.} =
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
    if irc.status == SockConnected:
      var line = await irc.sock.recvLine()
      var ev = irc.processLine(line)
      await irc.handleLineEvents(ev)
      asyncCheck irc.handleEvent(irc, ev)
    else:
      await sleepAsync(500)

