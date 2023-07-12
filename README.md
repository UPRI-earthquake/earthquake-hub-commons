# earthquake-hub-commons
Common dependencies for the EarthquakeHub web app

## Deployment Testing
The docker compose file contains spins up all the containers for the webapp: map-view, profile-view, admin-view. In the current version, only the map-view of the webapp has been implemented so far. 

Before spinning up the containers, make sure to:
1. Configure the env variables in [.dep-test.env.example](.dep-test.env.example) and rename it to `.dep-test.env`
2. Create a locally trusted self-signed SSL certificate (you may use [mkcert](https://www.howtoforge.com/how-to-create-locally-trusted-ssl-certificates-with-mkcert-on-ubuntu/) to do this). And store the `pem` files in `https_data/certbot/conf/live/<server-name>/` 
3. Configure the [nginx configuration file](https_data/nginx.dep-test.d/nginx.dep-test.conf):
    > ℹ️  If you name your `pem` files as `localhost+1.pem` and `localhost+1-key.pem`, and then store them in the folder `https_data/certbot/conf/live/localhost/`, then you shouldn't have to alter the nginx configuration file.
    1. `server_name` must match the one set for the certificates
    2. `ssl_certificate` and `ssl_certificate_key` should both correspond to the location and filenames of the previously generated `pem` files.
4. Make sure that ringserver-configs/auth/secret.key exists (contains brgy token to AuthServer).
5. Make sure that in ringserver-configs/ring.conf, AuthServer is set to the address of AuthServer API address (ie http://172.21.0.3:5000...). 

Finally, to run all the containers for deployment testing:
```bash
docker compose --env-file .dep-test.env up --build
```

Take note:
1. The compose file pulls the following images from the corresponding github repo's:
    1. [earthquake-hub-frontend](https://github.com/prokorpio/earthquake-hub-frontend/pkgs/container/earthquake-hub-frontend)
    2. [earthquake-hub-backend](https://github.com/prokorpio/earthquake-hub-backend/pkgs/container/earthquake-hub-backend)
2. [Authenticating with personal access token](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-with-a-personal-access-token-classic) is necessary to pull from `ghcr.io`.
3. The image versions must be set manually to whichever version is desired (`latest` tag is not used).
4. Note that the creation of self-signed SSL certificate is only for testing. For actual deployment, [usage of certbot](https://mindsers.blog/post/https-using-nginx-certbot-docker/) will replace this. (TODO: create deployment version of docker-compose.yml)

## Test Data
Test data for the DB containers: `mongo` and `mysql`, are correspondingly available in [deploymentTesting/](deploymentTesting/). A [bash script](deploymentTesting/mongodb/import_data.sh) can be used to import the data from the json files into the persistent volume of the running mongodb container. Note that the volume may then be used by other repositories, so that data can be shared regardless of which repository is run.

Take note:
1. Prior to running the compose file, make sure to create the volume via:
```bash
docker volume create earthquake-hub-mongodb-data
```
2. Before executing the bash script, make sure that the corresponding container (see CONTAINER_NAME in script) is running.
