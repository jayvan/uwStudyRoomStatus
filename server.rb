require 'json/ext'
require 'mongo'
require 'newrelic_rpm'
require 'sinatra'
require 'sinatra/cross_origin'

include Mongo

configure do
  enable :cross_origin

  db = MongoClient.new(ENV['MONGO_HOST'], ENV['MONGO_PORT']).db(ENV['MONGO_DB'])
  auth = db.authenticate(ENV['MONGO_USER'], ENV['MONGO_PASS'])

  set :mongo_db, db
end

get '/' do
  content_type :json

  rooms_db = settings.mongo_db.collection("rooms")
  rooms = rooms_db.find.to_a

  rooms.each do |room|
    room.delete('_id')
  end

  rooms.to_json
end
