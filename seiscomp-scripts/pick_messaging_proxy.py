import sys, traceback, seiscomp.client
import redis
import json

class PickListener(seiscomp.client.Application):

    def __init__(self):
        seiscomp.client.Application.__init__(self, len(sys.argv), sys.argv)
        self.setMessagingEnabled(True)
        self.setDatabaseEnabled(True,True)
        self.setPrimaryMessagingGroup(seiscomp.client.Protocol.LISTENER_GROUP)
        self.channel = "PICK"
        self.addMessagingSubscription(self.channel)

        # setup Redis pub/sub channel
        self.publisher = redis.Redis(host='172.22.0.5', port=6379)

    def doSomethingWithPick(self, pick):
        try:
            data = json.dumps({
                "networkCode": pick.waveformID().networkCode(),
                "stationCode": pick.waveformID().stationCode(),
                "timestamp": pick.time().value().seconds() 
            })
            self.publisher.publish("SC_"+self.channel, data)
            print("networkCode:", pick.waveformID().networkCode())
            print("stationCode:", pick.waveformID().stationCode())
            print("timestamp:", pick.time().value().seconds())

        except:
            info = traceback.format_exception(*sys.exc_info())
            for i in info: sys.stderr.write(i)

    def addObject(self, parentID, object):
        pick = seiscomp.datamodel.Pick.Cast(object)
        if pick:
            print("Received new pick %s" % pick.publicID())
            self.doSomethingWithPick(pick)

    def run(self):
        print("PickListener is now running.")
        return seiscomp.client.Application.run(self)

app = PickListener()
sys.exit(app())
