# multiplex_cdn

the media store (that will be) used by Multiplex for pfps

## reasoning

i wanted the bot to be more self-dependent and also wanted to avoid dealing with things like garage & minio

## api

you won't be accessing this directly if using the multiplex api, but if you are (for some reason) going to use the store itself, the api is very simple

-   `PUT /[filename]`: uploads a filename; takes a json body along the lines of `{
    "body": "[base64 encoded string of the file]",
    "mime_type": "[mimetype of the file]"
}`
-   `GET /[filename]`: returns the content of a file

## todo

(i should probably do most these before actually deploying)

-   [ ] avoid path traversal
-   [ ] DELETE endpoint
-   [ ] multi-node support (just blindly replicating between nodes?)
