import irc, asyncdispatch, strutils

proc onIrcEvent(client: AsyncIrc, event: IrcEvent) {.async.} =
  case event.typ
  of EvConnected:
    return
  of EvDisconnected, EvTimeout:
    await client.reconnect()
  of EvMsg:
    if event.cmd == MPrivMsg:
      var msg = event.params[event.params.high]
      if msg == "!test": await client.privmsg(event.origin, "hello")
      if msg == "!lag":
        await client.privmsg(event.origin, formatFloat(client.getLag))
      if msg == "!excessFlood":
        for i in 0..10:
          await client.privmsg(event.origin, "TEST" & $i)
      if msg == "!users":
        await client.privmsg(event.origin, "Users: " &
            client.getUserList(event.origin).join("A-A"))
    echo(event.raw)

var client = newAsyncIrc("irc.freenode.net", nick="TestBot1234",
                 proxyAddr="proxyaddress", proxyPort=<proxyport>.Port, joinChans = @["#nim-offtopic"], callback = onIrcEvent)
asyncCheck client.run()

runForever()
