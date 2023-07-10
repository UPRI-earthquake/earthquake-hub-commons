# Based on scbulletin

import sys, traceback, seiscomp.client, seiscomp.datamodel
import seiscomp.seismology
import redis
import json

class EventListener(seiscomp.client.Application):

    def __init__(self):
        seiscomp.client.Application.__init__(self, len(sys.argv), sys.argv)
        self.setMessagingEnabled(True)
        self.setDatabaseEnabled(True, True)
        self.setPrimaryMessagingGroup(seiscomp.client.Protocol.LISTENER_GROUP)
        self.setLoadRegionsEnabled(True)
        self.channel = "EVENT"
        self.addMessagingSubscription(self.channel)

        self.publisher = redis.Redis(host='172.22.0.5', port=6379)

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
            reg = seiscomp.seismology.Regions()
            region = reg.getRegionName(lat, lon)

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
            data = json.dumps({
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
            })
            self.publisher.publish('SC_'+self.channel, data)

        except:
            info = traceback.format_exception(*sys.exc_info())
            for i in info: sys.stderr.write(i)

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
        # connect to default configured global database 
        self._dbq = seiscomp.datamodel.DatabaseQuery(self.database()) 
        print("The EventListener is now running.")
        return seiscomp.client.Application.run(self)

app = EventListener()
sys.exit(app())
