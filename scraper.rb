#!/usr/bin/env ruby

# This script parses the HTML Tables from https://bookings.lib.uwaterloo.ca/sbs/day.php
# It grabs the room availability for the next week and stores it in a MongoDB specified
# by environment variables
# Mongodb://MONGO_USER:MONGO_PASS@MONGO_HOST:MONGO_PORT/MONGO_DB

require 'cgi'
require 'mongo'
require 'nokogiri'
require 'open-uri'

include Mongo

# The list of areas that we want availability data for.
# Currently the Cambridge campus is ommitted.
AREAS = [2, # DC - Group Study
         8, # DP - Group Study
         7] # DC - Single Study

@rooms = {}

# Fetches the data for the given day/area
def fetch_area(date, area)
  # The initial + for the dayChanger arg is intentional. They put the day of the week
  # e.g. 'Monday' as the first arg, but ignore it completely. Essentially we are sending
  # and empty arg
  url = "https://bookings.lib.uwaterloo.ca/sbs/day.php?area=#{area}&dayChanger=+#{date.day}+#{date.month}+#{date.year}"
  puts "Getting #{date} bookings for area #{area} from #{url}"
  page = Nokogiri::HTML(open(url))

  room_names = []
  room_capacities = []
  room_ids = nil
  num_rooms = 0;

  header = page.search('#day_main th')[1..-2]
  num_rooms = header.count

  # Get the names & capacities of study rooms in this area
  header.each do |room_el|
    # The room name is the first span in the header
    room_names << room_el.children[0].text.strip

    # The capacity is the second span, it follows 'Capacity: '
    room_capacities << room_el.children[1].text[10..-1].to_i
  end

  # Getting the ID of a room is a big pain because the page uses colspans
  # We need to find a row that has every room free
  # Since we crawl the availability from 1 week away down to today
  # odds are all rooms will be available
  page.search('#day_main tbody tr').each do |row|
    # If the given row doesn't have data for all the rooms we can't use it
    next if row.search('.new_booking').count != num_rooms

    room_ids = row.search('.new_booking').map do |td|
      args = CGI.parse(URI.parse(td.attributes['href'].value).query)
      args['room'][0].to_i
    end

    break
  end

  # If we couldn't get all the IDs for the rooms just skip this area
  if room_ids == nil
    return
  end

  # Store data for all of the rooms
  room_ids.each_with_index do |id, i|
    if @rooms[id] == nil
      @rooms[id] = {
        :bookings => [],
        :capacity => room_capacities[i],
        :id => id,
        :name => room_names[i]
      }
    end
  end

  # Go through all of the available bookings and record their availabilities
  page.search('.new_booking').each do |booking|
    args = CGI.parse(URI.parse(booking.attributes['href'].value).query)
    room_id = args['room'][0].to_i
    time = Time.new(args['year'][0], args['month'][0], args['day'][0], args['hour'][0], args['minute'][0])
    @rooms[room_id][:bookings] << time
  end
end

def fetch_date(date)
  AREAS.each do |area_id|
    fetch_area(date, area_id)
  end
end

def fetch
  days = 6.downto(0).map {|n| Date.today + n}

  days.each do |day|
    fetch_date(day)
  end
end

# Convert the individual times that rooms are available into blocks
def condense_blocks
  @rooms.each do |room_id, room|
    blocks = []
    start_time = room[:bookings][0]
    bookings_in_block = 1

    room[:bookings][1..-1].each.with_index(1) do |booking, index|
      if booking != start_time + 30 * 60 * bookings_in_block then
        end_time = room[:bookings][index - 1] + 30 * 60

        blocks << {
          :start => start_time,
          :duration => (end_time - start_time) / 60
        }

        start_time = booking
        bookings_in_block = 1
      else
        bookings_in_block += 1
      end
    end

    blocks << {
      :start => start_time,
      :duration => (room[:bookings][-1] + 30 * 60 - start_time) / 60
    }

    room[:bookings] = blocks
  end
end

def save_to_mongo
  db = MongoClient.new(ENV['MONGO_HOST'], ENV['MONGO_PORT']).db(ENV['MONGO_DB'])
  auth = db.authenticate(ENV['MONGO_USER'], ENV['MONGO_PASS'])

  if not auth
    puts "Could not connect to MongoDB"
    return
  end

  rooms_db = db.collection("rooms")

  @rooms.values.each do |room|
    rooms_db.find_and_modify({
      :query => {id: room[:id]},
      :update => room,
      :upsert => true
    })
  end
end

fetch
condense_blocks
save_to_mongo
