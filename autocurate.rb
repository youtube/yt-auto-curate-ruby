#!/usr/bin/ruby
#  Copyright 2011 Google Inc. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require 'rubygems'
require 'google/api_client'
require 'json'
require 'logger'
require 'oauth/oauth_util'
require 'thread'
require 'trollop'

YOUTUBE_API_READ_WRITE_SCOPE = 'https://www.googleapis.com/auth/youtube'
YOUTUBE_SERVICE = 'youtube'
YOUTUBE_VERSION = 'v3'
INVALID_CREDENTIALS_MESSAGE = 'Invalid Credentials'
LAST_UPDATED_KEY = 'last_updated'
UPLOADS_LIST_ID_KEY = 'uploads_list_id'
ACTIONS_KEY = 'actions'
REGEX_KEY = 'regex'
PLAYLIST_ID_KEY = 'playlist_id'
BULLETIN_KEY = 'bulletin'

Log = Logger.new(STDOUT)

def initialize_log(debug)
  Log.formatter = proc do |severity, time, progname, msg|
    return "#{time} [#{severity}]: #{msg}\n"
  end

  Log.level = debug ? Logger::DEBUG : Logger::INFO
end

def initialize_api_clients
  client = Google::APIClient.new(:application_name => $0, :application_version => '1.0')
  youtube = client.discovered_api(YOUTUBE_SERVICE, YOUTUBE_VERSION)

  auth_util = CommandLineOAuthHelper.new([YOUTUBE_API_READ_WRITE_SCOPE])
  client.authorization = auth_util.authorize()

  return client, youtube
end

def load_config(file)
  Log.debug("Reading configuration from #{file}.")
  return JSON.parse(IO.read(file))
end

def write_config(file, config)
  Log.debug("Writing configuration to #{file}.")
  File.open(file, 'w') do |file|
    file.write(JSON.pretty_generate(config))
  end
end

def get_new_videos(client, youtube, list_id, last_update_ticks)
  videos = []
  next_page_token = ''

  begin
    until next_page_token.nil?
      Log.debug("Fetching #{list_id} with page token #{next_page_token}...")
      playlistitems_list_response = client.execute!(
        :api_method => youtube.playlist_items.list,
        :parameters => {
          :playlistId => list_id,
          :part => 'snippet',
          :maxResults => 50,
          :pageToken => next_page_token
        }
      )

      playlistitems_list_response.data.items.each do |playlist_item|
        video_id = playlist_item.snippet.resourceId.videoId
        published_at = playlist_item.snippet.publishedAt.to_i
        if published_at > last_update_ticks
          Log.debug("Found #{video_id}, which was published at #{published_at}. Adding to list.")
          videos << playlist_item
        else
          Log.debug("Found #{video_id}, which was published at #{published_at}. Breaking.")
          next_page_token = nil
          break
        end
      end

      next_page_token = playlistitems_list_response.data.next_page_token unless next_page_token.nil?
    end
  rescue Google::APIClient::TransmissionError => transmission_error
    Log.error("Error while calling playlistItems.list(): #{transmission_error}")
  ensure
    return videos.reverse!
  end
end

def process_video_ids(client, youtube, videos, actions)
  last_updated_ticks = nil

  begin
    actions.each do |action|
      regex = Regexp.new(action[REGEX_KEY])
      videos.each do |video|
        if regex =~ video.snippet.title
          if action.has_key?(PLAYLIST_ID_KEY)
            add_video_to_playlist(client, youtube, action[PLAYLIST_ID_KEY], video.snippet.resourceId.videoId)
          end

          if action.has_key?(BULLETIN_KEY):
            post_bulletin(client, youtube, action[BULLETIN_KEY], video.snippet.resourceId.videoId)
          end

          last_updated_ticks = video.snippet.publishedAt.to_i
        end
      end
    end
  rescue Google::APIClient::TransmissionError => transmission_error
    Log.error("Error while making API call: #{transmission_error}")
  ensure
    return last_updated_ticks
  end
end

def add_video_to_playlist(client, youtube, playlist_id, video_id)
  Log.info("Adding #{video_id} to #{playlist_id}.")

  body = {
    :snippet => {
      :playlistId => playlist_id,
      :position => 0,
      :resourceId => {
        :kind => 'youtube#video',
        :videoId => video_id
      }
    }
  }

  client.execute!(
    :api_method => youtube.playlist_items.insert,
    :parameters => {
      :part => body.keys.join(',')
    },
    :body_object => body
  )
end

def post_bulletin(client, youtube, message, video_id)
  Log.info("Adding channel bulletin for #{video_id}.")

  body = {
    :snippet => {
      :description => message
    },
    :contentDetails => {
      :bulletin => {
        :resourceId => {
          :kind => 'youtube#video',
          :videoId => video_id
        }
      }
    }
  }

  client.execute!(
    :api_method => youtube.activities.insert,
    :parameters => {
      :part => body.keys.join(',')
    },
    :body_object => body
  )
end

if __FILE__ == $PROGRAM_NAME
  opts = Trollop::options do
    opt :config, 'Path to configuration file', :type => String, :default => 'config.json'
    opt :debug, 'Enable for extra logging info'
  end

  initialize_log(opts[:debug])
  Log.info("Starting up.")

  Trollop::die :config, 'must refer to an existing config file' unless File.exists?(opts[:config])
  configs = load_config(opts[:config])
  Log.debug("Using configs: #{configs.to_json}")

  client, youtube = initialize_api_clients()

  begin
    configs.each do |config|
      config[LAST_UPDATED_KEY] = 0 unless config.has_key?(LAST_UPDATED_KEY)
      new_videos = get_new_videos(client, youtube, config[UPLOADS_LIST_ID_KEY], config[LAST_UPDATED_KEY])
      last_updated_ticks = process_video_ids(client, youtube, new_videos, config[ACTIONS_KEY])
      config[LAST_UPDATED_KEY] = last_updated_ticks unless last_updated_ticks.nil?
    end
  ensure
    write_config(opts[:config], configs)
  end

  Log.info('All done.')
end