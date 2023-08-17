# Based on scbulletin

import sys, traceback, seiscomp.client, seiscomp.datamodel
import seiscomp.seismology
import requests
import json

EARTHQUAKE_HUB_URL = "http://172.21.0.3:5000" # Change this to IP address of earthquake-hub-backend

class EventListener(seiscomp.client.Application):

    def __init__(self):
        seiscomp.client.Application.__init__(self, len(sys.argv), sys.argv)
        self.setMessagingEnabled(True)
        self.setDatabaseEnabled(True, True)
        self.setPrimaryMessagingGroup(seiscomp.client.Protocol.LISTENER_GROUP)
        self.setLoadRegionsEnabled(True)
        self.channel = "EVENT"
        self.addMessagingSubscription(self.channel)

    def doSomethingWithEvent(self, event, eventType):
        try:
            # load origin
            prefOrgID = event.preferredOriginID()
            org = seiscomp.datamodel.Origin.Find(prefOrgID)
            if not org:
                # TODO: Might be more efficient to keep a cache of
                #       of recent events, origins, and magnitudes
                print('Loading origin from db')
                org = self._dbq.loadObject(
                    seiscomp.datamodel.Origin.TypeInfo(), prefOrgID)
                org = seiscomp.datamodel.Origin.Cast(org)
                if not org:
                    print('Origin cannot be loaded')
                    return

            # get values of interest from Origin obj
            depth = int(org.depth().value()+0.5)
            OT = org.time().value().toString("%Y-%m-%dT%H:%M:%S.000Z")
            lat = org.latitude().value()
            lon = org.longitude().value()
            method = org.methodID()

            # get region of lat,lon
            region = seiscomp.seismology.Regions.getRegionName(lat, lon)

            # get last modification to this event
            creationInfo = event.creationInfo()
            if eventType == 'NEW':
                lastModified = creationInfo.creationTime()\
                                   .toString("%Y-%m-%dT%H:%M:%S.000Z")
            elif eventType == 'UPDATE': 
                lastModified = creationInfo.modificationTime()\
                                   .toString("%Y-%m-%dT%H:%M:%S.000Z")

            # get prefMag from origin, if mag is its child
            prefMagID = event.preferredMagnitudeID()
            mag_val = 0.
            foundMag = False
            for i in range(org.magnitudeCount()):
                mag = org.magnitude(i)
                if mag.publicID() == prefMagID:
                    mag_val = mag.magnitude().value()
                    foundMag = True
                    break

            # find via current runtime public objects
            if not foundMag:
                mag = seiscomp.datamodel.Magnitude.Find(prefMagID)

                if mag is None:
                    print('Loading magnitude from db')
                    mag = self._dbq.loadObject(
                        seiscomp.datamodel.Magnitude.TypeInfo(), prefMagID)
                    mag = seiscomp.datamodel.Magnitude.Cast(mag)

                if mag:
                    mag_val = mag.magnitude().value()

            print('{\n' \
                + f'  eventType: {eventType}\n' \
                + f'  publicID: {event.publicID()}\n' \
                + f'  OT: {OT}\n' \
                + f'  latitude_value: {lat}\n' \
                + f'  longitude_value: {lon}\n' \
                + f'  depth_value: {depth}\n' \
                + f'  magnitude_value: {mag_val}\n' \
                + f'  text: {region}\n' \
                + f'  method: {method}\n' \
                + f'  last_modification: {lastModified}\n' \
                + '}'
            )

            data = {
                "eventType": eventType,
                "publicID": event.publicID(),
                "OT": OT,
                "latitude_value": lat,
                "longitude_value": lon,
                "depth_value": depth,
                "magnitude_value": mag_val,
                "text": region,
                "method": method,
                "last_modification": lastModified
            }

            response = requests.post(EARTHQUAKE_HUB_URL + "/messaging/restricted/new-event", json=data)
            if response.status_code == 200:
                print("Event added successfully.")
            else:
                print("Failed to add event:", response.text)

        except Exception as e:
            traceback.print_exc()

    def updateObject(self, parentID, object):
        # called if an update-object is received
        event = seiscomp.datamodel.Event.Cast(object)
        if event:
            print("UPDATE for event %s" % event.publicID())
            self.doSomethingWithEvent(event, 'UPDATE')

    def addObject(self, parentID, object):
        # called if a new object is received
        event = seiscomp.datamodel.Event.Cast(object)
        if event:
            print("NEW event %s" % event.publicID())
            self.doSomethingWithEvent(event, 'NEW')

    def run(self):
        # connect to the default configured global database
        self._dbq = seiscomp.datamodel.DatabaseQuery(self.database())
        print("The EventListener is now running.")
        return seiscomp.client.Application.run(self)

app = EventListener()
sys.exit(app())
