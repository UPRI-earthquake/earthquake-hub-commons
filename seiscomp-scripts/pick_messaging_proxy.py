import sys, traceback, seiscomp.client
import requests
import json

EARTHQUAKE_HUB_URL = "https://10.196.16.108/api" # Change this to IP address of earthquake-hub-backend

class PickListener(seiscomp.client.Application):

    def __init__(self):
        seiscomp.client.Application.__init__(self, len(sys.argv), sys.argv)
        self.setMessagingEnabled(True)
        self.setDatabaseEnabled(True,True)
        self.setPrimaryMessagingGroup(seiscomp.client.Protocol.LISTENER_GROUP)
        self.channel = "PICK"
        self.addMessagingSubscription(self.channel)

    def doSomethingWithPick(self, pick):
        try:
            data = {
                "networkCode": pick.waveformID().networkCode(),
                "stationCode": pick.waveformID().stationCode(),
                "timestamp": pick.time().value().toString("%Y-%m-%dT%H:%M:%S.000Z")
            }

            response = requests.post(EARTHQUAKE_HUB_URL + "/messaging/new-pick", json=data)
            if response.status_code == 200:
                print("Pick sent successfully.")
            else:
                print("Failed to send pick:", response.text)

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
