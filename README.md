# kafka-connect-docker
Docker image with sofware to run kafka connects

# Docker Compose example #

To run example in distributed mode with using docker compose follow next steps:

* Git clone or download and extract zip from github.

* Change to docker-compose example:

  ```
  cd docker-compose
  ``

* Create topics

  ```
  docker-compose up create-topics
  ```

* Run the rest of pipeline

  ```
  docker-compose up target
  ```

After a few minutes you can se output in `files/data/test-output.txt`

The pipeline consist in launch two connectors over kafa connect server.

One (config in `files/kconnect/input.properties`) loads data from
`files/data/test.txt`file and push to `test-topic`.

And other (config in `files/kconnect/input.properties`) one loads data from
`test-topic` and save in `files/data/test-output.txt`.

## Clean docker-compose services ##

* After file was saved (`files/data/test-output.txt`) you can delete all services
  with:

  ```
  docker-compose down
  ```

* Clean building local images.

  ```
  docker images  | awk '$1~/dockercompose/{print $3}' | xargs docker rmi -f
  ```

  Please, have in mind, that last command delete all local docker images which
  name contains `dockercompose`. This is default project name set by docker-compose
  (it is extracted from `docker-compose` path where example is saved).

* Clean local docker volumes.

  ```
  docker volume prune -f
  ```
