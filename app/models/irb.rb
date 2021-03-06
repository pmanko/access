class Irb < ActiveRecord::Base
  ##
  # Associations
  has_many :subjects, :through => :subjects_irbs
  has_many :subjects_irbs

  ##
  # Attributes
  # attr_accessible :number, :title

  ##
  # Callbacks

  ##
  # Concerns
  include Loggable, Deletable

  ##
  # Database Settings

  ##
  # Scopes

  ##
  # Validations
  validates_presence_of :irb_number, :title
  validates_uniqueness_of :irb_number

  ##
  # Class Methods

  ##
  # Instance Methods

  private
end
